# Local patch — easy_video_editor 0.1.6

This is a vendored, hand-patched copy of `easy_video_editor` 0.1.6
(https://pub.dev/packages/easy_video_editor), kept in this repo because the
published version fails to compile on Xcode's newer Swift toolchain (the one
Codemagic's `flutter build ipa` uses). As of this patch, pub.dev has no newer
release and the upstream fix PRs (iawtk2302/easy_video_editor#48 and #50) are
still open and unmerged.

Two separate, real bugs in the package's iOS Swift source, confirmed by
pulling the actual 0.1.6 source from the local pub cache and reading it
directly (not guessed from a diff):

1. **`utils/OperationManager.swift` and `utils/ProgressManager.swift` are
   missing `import Foundation`.** Both reference `DispatchWorkItem`,
   `DispatchQueue`, `UUID`, `.concurrent`, `.barrier` — all from
   Foundation/Dispatch — with nothing importing them. This is the exact
   failure from the Codemagic build log:
   `Cannot find type 'DispatchWorkItem' in scope`, `Cannot find 'UUID' in
   scope`, `Cannot infer contextual base in reference to member 'barrier'`,
   etc. Fix: added `import Foundation` to both files.

2. **Every command handler (`handler/*Command.swift`, 11 files including
   `MergeVideosCommand.swift` — the one this app actually calls via
   `VideoEditorBuilder(...).merge(...)`) declares its cancelable work item
   as a self-referencing `lazy var`:**
   ```swift
   lazy var workItem: DispatchWorkItem = DispatchWorkItem {
       if workItem.isCancelled { ... } // refers to itself before it's fully declared
   }
   ```
   Newer Swift rejects this. This is the same bug the two open upstream PRs
   fix, with the same solution — declare the variable first, assign the
   closure after:
   ```swift
   var workItem: DispatchWorkItem!
   workItem = DispatchWorkItem {
       if workItem.isCancelled { ... } // now just captures the outer var, not itself
   }
   ```
   Applied to: AdjustVideoSpeedCommand, CompressVideoCommand, CropVideoCommand,
   ExtractAudioCommand, FlipVideoCommand, GenerateThumbnailCommand,
   GetFrameCommand, MergeVideosCommand, RemoveAudioCommand, RotateVideoCommand,
   TrimVideoCommand.

Everything else in this vendored copy is untouched, byte-for-byte, from the
real published 0.1.6 package (pulled from
`~/AppData/Local/Pub/Cache/hosted/pub.dev/easy_video_editor-0.1.6` on this
machine, which is where `flutter pub get` had already downloaded it).

The `android/`, `example/`, and `test/` folders from the original package are
deliberately **not** vendored here — this app only ever builds for iOS via
Codemagic, and neither `flutter build ipa` nor CocoaPods/SPM for the iOS
target touches those folders for any dependency. If this project ever adds
an Android build, those folders will need to be added back from the real
package (unpatched — the bugs above are iOS/Swift-only).

## How this is wired up

`pubspec.yaml` has a `dependency_overrides:` entry pointing `easy_video_editor`
at this folder (`path: third_party/easy_video_editor`) instead of pub.dev.
The regular `dependencies:` entry further up still lists the pub.dev version
too — that's intentional and required by Dart (an override needs something
to override), but as long as the override is present, pub always resolves to
this local, patched copy.

## If upstream ever ships a real fix

Check https://pub.dev/packages/easy_video_editor/versions for a version
newer than 0.1.6. If one exists and its changelog mentions these Swift
compile issues, it's worth trying: bump the `easy_video_editor:` version in
the main `dependencies:` block and delete the `dependency_overrides:` entry
and this whole `third_party/easy_video_editor/` folder, then rebuild. Revert
if it still fails.
