// This route is never actually shown — the tab's `listeners.tabPress` in
// `_layout.tsx` calls `e.preventDefault()` and pushes the real `/create`
// modal instead. The file still has to exist for Expo Router to resolve
// the tab, same as the prototype's centre "+" button opens a sheet rather
// than switching screens.
export default function CreateTabPlaceholder() {
  return null;
}
