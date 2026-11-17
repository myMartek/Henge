UEFI firmware for the Windows PC: TianoCore EDK2 ArmVirtQemu (BSD-2-Clause-Patent), as shipped with QEMU 9.2.0
(pc-bios/edk2-aarch64-code.fd.bz2 and edk2-arm-vars.fd.bz2, https://gitlab.com/qemu-project/qemu). Each unpacks to 64 MB.
The code image is changed in one place (WindowsiOS/xros/patch_firmware.py): the framebuffer driver's three modes
(640x480, 800x600, 1024x768) are 1280x720, 1600x900 and 1920x1080.

netkvm.*: Red Hat's VirtIO network driver for Windows 11 on ARM64, from virtio-win 0.1.302 (NetKVM/w11/ARM64).

Licences: EDK2-LICENSE.txt for the firmware, NetKVM-LICENSE.txt for the driver.
