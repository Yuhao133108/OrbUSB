# USB storage Attach

## Implementation and limits

`OrbStackUSBService` is the transaction coordinator. Its actor-owned device map
excludes overlapping attach/detach operations across suspension points. AppState
keeps row operation state separately from refreshed device values and owns task
cancellation on shutdown. Duplicate requests are rejected, never queued for later.

Storage preparation uses one process-lifetime Disk Arbitration session on a serial
queue. Pending devices are matched using location ID, VID/PID, serial when present,
and the IORegistry entry ID for the original USB connection. Mount approval walks
IOMedia's IOService ancestors; unrelated disks remain allowed. The startup disk is
excluded. A changed USB connection is rejected even if its serial is identical.

Sequence:

1. Acquire the device operation, mark pending before any OrbStack refresh.
2. Find physical whole IOMedia (8-second discovery timeout).
3. Check zero IOKit busy state and discover every descendant medium. Await a DA
   claim completion for each medium, then immediately unclaim while keeping mount
   veto active (8-second shared deadline). DA dispatches claim after appearance
   and after the active per-disk command; this handles failed mounts that never
   publish VolumePath. Recheck lifecycle readiness before normal unmount.
4. Discover synthesized APFS whole disks through IOService ancestry. Submit normal
   `DADiskUnmount` with `kDADiskUnmountOptionWhole` for those containers first and
   then each physical whole disk, sequentially; await every completion (8-second
   callback timeout). Physical-store unmount alone does not cover APFS containers.
5. Verify all descendant volumes, including synthesized APFS media reachable through
   IOService ancestry: no DA VolumePath and no corresponding `getmntinfo` mount.
   Unknown/incomplete descriptions fail closed (8-second verification timeout).
6. Debounce 350 ms only after successful callbacks and verification.
7. Refresh OrbStack; verify connection identity, cancellation, original IOMedia,
   unchanged whole disks and child-media topology, lifecycle generation, IOKit
   busy state and absence of all host mounts again.
8. Invoke attach with mount prevention held until the command finishes.
9. Clear pending state before releasing the transaction, including on failure.

Timeout cannot cancel a Disk Arbitration operation. A timed-out callback loses
its continuation but retains a small media quarantine until the callback arrives.
A late callback consumes that tombstone, never revives an attach task. No forced
unmount or eject fallback exists. A failed mount need not publish a description
change; the explicit arbitration barrier resolves that uncertainty without
clearing a pending flag based merely on elapsed time.

Apple's public Disk Arbitration APIs provide mount/unmount arbitration, **not an
atomic kernel USB ownership-transfer primitive**. This implementation gates attach
on the observable host lifecycle, but cannot prove that every private SCSI/USB
kernel teardown has finished or that no unplug/event occurs between the final
check and the OrbStack process taking ownership. A strict kernel-level guarantee
requires coordination in OrbStack/the host driver; passing these tests must not be
reported as proof that kernel panic is impossible.

References: [Apple callback guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ArbitrationBasics/ArbitrationBasics.html),
[Apple DA staging implementation](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DAStage.c),
and the installed SDK DiskArbitration headers. DA's initial stage order is probe,
peek, mount, then appeared; a peek alone is not automount completion.

## Validation

Automated XCTest coverage uses a fake OrbStack executable and controllable storage
preparation to verify ordering, multi-disk preparation, active-mount blocking,
10 duplicate requests, detach exclusion, failure cleanup/retry, cancellation,
refresh/model replacement, changed connections, ordinary USB behavior, and
exactly-once continuation handling for success, dissent, timeout and late callback.
Pure lifecycle tests cover probe, initial/later mount and BSD-name reuse.
These tests do not perform physical USB ownership transfers.

Hardware acceptance remains to be run on the affected Mac/macOS/OrbStack versions.
Use the debug `[USB Attach]` logs and independently inspect DA descriptions/mount
entries; Finder icons are not evidence of unmount completion.

| Case | Procedure | Required result |
| --- | --- | --- |
| 1 | Attach an already mounted disk | Whole-disk callback success, verification, then one attach |
| 2 | Click immediately after insertion, before a volume appears | Wait for DA/IOKit or veto mount; never early attach |
| 3 | Click while automount is running | Wait for completion, then normal unmount and verification |
| 4 | Click Attach 5–10 times | One transaction and one CLI attach |
| 5 | Use a GPT disk with EFI and several partitions | Every child mount absent before attach |
| 6 | Use APFS with several volumes | All synthesized volume mounts absent before attach |
| 7 | Keep a file in use so normal unmount dissents | Error; no force, eject or attach |
| 8 | Unplug during discovery/mount/unmount/debounce | Abort; no old request resumes ownership transfer |
| 9 | Refresh repeatedly during preparation | Phase persists; no duplicate operation |
| 10 | Attach/detach keyboard, serial, audio or network USB | Existing non-storage behavior preserved |

Also test two identical disks on different ports, startup-disk rejection, a late
unmount callback after timeout, and detach followed by host automount. Record OS,
OrbStack version, filesystem/partition layout and log ordering for each run.

## Hardware observation — 2026-09-11

With a RTL9210C (0bda:9210), approximately 1 TB GPT disk with EFI and APFS,
the physical disk mapped to disk4 and its synthesized APFS container to disk5
with two mounted volumes. The initial physical-only whole-disk unmount returned
success but left both APFS volumes mounted. Verification correctly aborted before
OrbStack attach. After including the synthesized container in the unmount plan,
all preparation gates passed and OrbStack confirmed attached. This validates the
already-mounted, multi-partition/APFS path on this device; immediate insertion,
active automount, busy files and mid-transaction unplug still need hardware runs.

Repeated-use diagnostics identified EFI disk4s1 remaining in "mount completion
pending" after a mount approval with no mounted description. Preparation now
uses claim completion as a per-medium request barrier; timeout/late success always
unclaims the disk. A real run completed barriers for disk4, disk4s1, disk4s2,
disk5, disk5s1 and disk5s2, then attached successfully. An immediate subsequent
OrbStack detach did not recreate any host IOMedia in the discovery deadline;
that distinct case safely aborted with diskNotFound and remains a hardware
recovery limitation, not evidence of another pending-mount flag timeout.

After deploying the arbitration-barrier fix, the user reported validation
passed and approved committing the changes. Automated validation: 46 XCTest
tests passed; Xcode MCP build completed without warnings. The user confirmation
does not specify coverage of every hardware scenario listed above.
