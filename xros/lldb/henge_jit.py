# SPDX-License-Identifier: GPL-2.0-or-later
"""Henge's JIT trap servicer for lldb (visionOS spike).

On iOS 26 and later an app gets executable memory only from an attached debugger: StikDebug runs
ios/Henge/Resources/henge-jit.js, which answers the app's brk instructions. This is the same protocol
for lldb, so that a Mac's debugger (Xcode's, or lldb on the command line) can do it for an Apple Vision Pro:

    brk #0x69                 -> x0 = 0xE0000069                       ("is a servicer attached?")
    brk #0xf00d, x16 = 1      -> x0 = an r-x region of x1 bytes        (debugserver's _M<size>,rx, then one
                                                                        byte written into every 16 KiB page)
    brk #0xf00d, x16 = 0      -> the app is done with the debugger

In lldb:
    command script import xros/lldb/henge_jit.py
    target stop-hook add -P henge_jit.Servicer [-k detach -v 1] [-k pages -v 0]
and launch Henge with HENGE_JIT_SERVICER=1 in its environment (JITBootstrap.prewarmVision).

  detach=1  stop when the app says it is done, so that a script can detach (the default keeps the debugger on)
  pages=N   write into the first N pages only; 0 for none (to find out what a device needs)
  bulk=N    write N whole pages at a time instead of one byte into each
  log=PATH  progress of long steps, since the hook's own output appears only when it returns
Each can also be set as HENGE_JIT_DETACH, HENGE_JIT_PAGES, HENGE_JIT_BULK, HENGE_JIT_LOG in lldb's environment.
"""
import os
import re
import time

import lldb

PAGE = 0x4000
STATE = {"done": False, "stuck": None}   # set once the app has said it is done with the debugger (henge_wait waits for it)
BRK_MASK, BRK_BITS = 0xFFE0001F, 0xD4200000


def _log(stream, text):
    stream.Print("[henge-jit.py] %s\n" % text)


class Servicer:
    def __init__(self, target, extra_args, internal_dict):
        self.target = target
        self.detach = self._arg(extra_args, "detach") == "1"
        pages = self._arg(extra_args, "pages")
        self.pages = int(pages) if pages and pages.isdigit() else None   # None: every page
        self.log = self._arg(extra_args, "log")
        bulk = self._arg(extra_args, "bulk")
        self.bulk = int(bulk) if bulk and bulk.isdigit() else 1
        self.served = 0
        self.notes = []

    @staticmethod
    def _arg(extra_args, key):
        """An option: -k KEY -v VALUE on the stop hook, or HENGE_JIT_<KEY> in lldb's environment (a path as a -v value
        made lldb refuse the hook)."""
        try:
            value = extra_args.GetValueForKey(key) if extra_args and extra_args.IsValid() else None
            if value and value.IsValid():
                text = value.GetStringValue(1024)
                if text:
                    return text
        except Exception:
            pass
        return os.environ.get("HENGE_JIT_" + key.upper())

    def handle_stop(self, exe_ctx, stream):
        """True leaves the process stopped; False resumes it."""
        try:
            return self._handle(exe_ctx, stream)
        except Exception:
            import traceback
            _log(stream, "servicer failed:\n" + traceback.format_exc())
            return True
        finally:
            for note in self.notes:
                _log(stream, note)
            self.notes = []

    def _handle(self, exe_ctx, stream):
        process = exe_ctx.GetProcess()
        thread = exe_ctx.GetThread()
        if thread.GetStopReason() != lldb.eStopReasonException:
            return True
        pc = self._get(thread, "pc")
        error = lldb.SBError()
        word = int.from_bytes(process.ReadMemory(pc, 4, error) or b"\0\0\0\0", "little")
        if error.Fail() or (word & BRK_MASK) != BRK_BITS:
            _log(stream, "stop that is not Henge's: %s at pc=%#x" % (thread.GetStopDescription(160), pc))
            STATE["stuck"] = "%s at pc=%#x" % (thread.GetStopDescription(160), pc)
            return True
        immediate = (word >> 5) & 0xFFFF
        if immediate == 0x69:
            self._set(thread, "x0", 0xE0000069)
            self._set(thread, "pc", pc + 4)
            self.served += 1
            _log(stream, "brk #0x69 (probe) answered at %#x" % pc)
            return False
        if immediate != 0xF00D:
            _log(stream, "brk #%#x is not Henge's; leaving the process stopped" % immediate)
            return True

        command = self._get(thread, "x16")
        x0, x1 = self._get(thread, "x0"), self._get(thread, "x1")
        self.served += 1
        if command == 0:
            self._set(thread, "pc", pc + 4)
            STATE["done"] = True
            _log(stream, "the app is done with the debugger (%d traps served)%s" % (self.served, "; stopping to detach" if self.detach else ""))
            return self.detach
        if command != 1:
            self._set(thread, "pc", pc + 4)
            _log(stream, "brk #0xf00d with unknown command %d skipped" % command)
            return False

        _log(stream, "brk #0xf00d: a region of %d MiB is asked for (x0=%#x)" % (x1 >> 20, x0))
        self._progress("region of %d MiB asked for" % (x1 >> 20))
        address = x0
        if address == 0 and x1 != 0:
            address = self._allocate_rx(thread, x1, stream)
            if address and self.pages != 0:
                if not self._touch_pages(process, address, x1 if self.pages is None else min(x1, self.pages * PAGE), stream):
                    address = 0   # a region only partly prepared would stop the app at the first page that is not
        self._set(thread, "x0", address)
        self._set(thread, "pc", pc + 4)
        return False

    def _allocate_rx(self, thread, size, stream):
        answer = self._packet(thread, "_M%x,rx" % size)
        if not re.fullmatch(r"[0-9a-fA-F]+", answer) or answer.upper().startswith("E"):
            _log(stream, "debugserver refused %d MiB of r-x memory: %s" % (size >> 20, answer))
            return 0
        address = int(answer, 16)
        _log(stream, "debugserver gave %d MiB of r-x memory at %#x" % (size >> 20, address))
        return address

    def _touch_pages(self, process, address, size, stream):
        """A write through the debugger into every page: what makes them usable (StikDebug's prepare_memory_region
        writes one byte into each). Each write is a round trip to the device, which is all the time this takes, so
        two bytes are written across the boundary between two pages: one round trip for both.
        bulk=N instead writes N whole pages at a time: fewer round trips, far more bytes."""
        start = time.time()
        count = (size + PAGE - 1) // PAGE
        error = lldb.SBError()
        writes = 0
        if self.bulk > 1:
            data = b"\x69" * (self.bulk * PAGE)
            for index in range(0, count, self.bulk):
                process.WriteMemory(address + index * PAGE, data[:min(self.bulk, count - index) * PAGE], error)
                writes += 1
                if error.Fail(): break
                if writes % 64 == 1: self._progress("page %d of %d after %.1f s" % (index, count, time.time() - start))
        else:
            for index in range(0, count, 2):
                if index + 1 < count:
                    process.WriteMemory(address + (index + 1) * PAGE - 1, b"\x69\x69", error)   # last byte of one, first of the next
                else:
                    process.WriteMemory(address + index * PAGE, b"\x69", error)
                writes += 1
                if error.Fail(): break
                if writes % 1024 == 1: self._progress("page %d of %d after %.1f s" % (index, count, time.time() - start))
        if error.Fail():
            _log(stream, "a write into the region failed after %d writes: %s" % (writes, error.GetCString()))
            return False
        self._progress("all %d pages after %.1f s" % (count, time.time() - start))
        _log(stream, "wrote into %d pages in %.1f s (%d writes)" % (count, time.time() - start, writes))
        return True

    def _progress(self, text):
        """The stream is shown only when the hook returns: a file says how far a long step is (-k log -v PATH)."""
        if self.log:
            with open(self.log, "a") as file:
                file.write("%s %s\n" % (time.strftime("%H:%M:%S"), text))

    # Registers go straight to debugserver (p and P packets, as StikDebug's script does it). lldb's own view cannot be
    # used inside a stop hook on a device: writes through it fail ("unable to write back to register"), and once a
    # register was set behind its back it kept showing the previous stop's values.
    @staticmethod
    def _number(name):
        return 0x20 if name == "pc" else int(name[1:])

    def _packet(self, thread, text):
        result = lldb.SBCommandReturnObject()
        interpreter = self.target.GetDebugger().GetCommandInterpreter()
        interpreter.HandleCommand("process plugin packet send %s" % text, lldb.SBExecutionContext(thread), result)
        output = ((result.GetOutput() or "") + (result.GetError() or "")).strip()
        match = re.search(r"response:\s*(\S*)\s*$", output)
        if not match:
            raise RuntimeError("no answer to %s: %s" % (text, output))
        return match.group(1)

    def _get(self, thread, name):
        answer = self._packet(thread, "p%x;thread:%x;" % (self._number(name), thread.GetThreadID()))
        if not re.fullmatch(r"[0-9a-fA-F]{16}", answer):
            raise RuntimeError("register %s read as %r" % (name, answer))
        return int.from_bytes(bytes.fromhex(answer), "little")

    def _set(self, thread, name, value):
        little = value.to_bytes(8, "little").hex()
        answer = self._packet(thread, "P%x=%s;thread:%x;" % (self._number(name), little, thread.GetThreadID()))
        if answer != "OK":
            raise RuntimeError("register %s write answered %r" % (name, answer))


def henge_wait(debugger, command, result, internal_dict):
    """henge_wait [SECONDS]: resume the attached process, let the servicer work until the app is done with the
    debugger (or SECONDS pass, 1800 by default), then detach and leave the app running."""
    seconds = float(command) if command.strip() else 1800.0
    process = debugger.GetSelectedTarget().GetProcess()
    debugger.SetAsync(True)
    error = process.Continue()
    print("henge_wait: resumed (%s)" % (error.GetCString() or "ok"))
    end = time.time() + seconds
    while time.time() < end and not STATE["done"] and not STATE["stuck"]:
        if process.GetState() in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            print("henge_wait: the app ended (%s)" % lldb.SBDebugger.StateAsCString(process.GetState()))
            return
        time.sleep(0.5)
    time.sleep(1.0)   # let the hook's stop arrive
    print("henge_wait: %s" % ("the app has its JIT region" if STATE["done"] else
                              "the app stopped on its own: %s" % STATE["stuck"] if STATE["stuck"] else "gave up after %.0f s" % seconds))
    error = process.Detach()
    print("henge_wait: detached (%s)" % (error.GetCString() or "ok"))


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f henge_jit.henge_wait henge_wait")
