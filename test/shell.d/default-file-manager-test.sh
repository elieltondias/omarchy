#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin" "$test_tmp/config" "$test_tmp/data/applications" \
  "$test_tmp/system/applications" "$test_tmp/system/dbus-1/services" \
  "$test_tmp/home/.config/hypr"

export HOME="$test_tmp/home"
export XDG_CONFIG_HOME="$test_tmp/config"
export XDG_CONFIG_DIRS="$test_tmp/etc"
export XDG_DATA_HOME="$test_tmp/data"
export XDG_DATA_DIRS="$test_tmp/system"
unset XDG_CURRENT_DESKTOP XDG_MENU_PREFIX

export OMARCHY_TEST_NOTIFICATION_HISTORY="$test_tmp/notification"
export OMARCHY_TEST_TERMINAL_LOG="$test_tmp/terminal"
export OMARCHY_TEST_PKG_LOG="$test_tmp/pkg"
export OMARCHY_TEST_MOCK_BIN="$mock_bin"
export OMARCHY_TEST_LAUNCH_LOG="$test_tmp/launch"
export OMARCHY_TEST_HYPRCTL_LOG="$test_tmp/hyprctl"

cat >"$mock_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >>"$OMARCHY_TEST_NOTIFICATION_HISTORY"
SH
cat >"$mock_bin/omarchy-launch-floating-terminal-with-presentation" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >"$OMARCHY_TEST_TERMINAL_LOG"
SH
cat >"$mock_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_PKG_LOG"
# Installing is what puts the command on PATH: become it, like pacman would.
for package in "$@"; do
  printf '#!/bin/bash\nexit 0\n' >"$OMARCHY_TEST_MOCK_BIN/$package"
  chmod +x "$OMARCHY_TEST_MOCK_BIN/$package"
done
SH
cat >"$mock_bin/uwsm-app" <<'SH'
#!/bin/bash
printf '%s\0' "$@" >"$OMARCHY_TEST_LAUNCH_LOG"
SH
cat >"$mock_bin/hyprctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_HYPRCTL_LOG"
SH

export PATH="$mock_bin:$ROOT/bin:$PATH"

# The file managers, each with the desktop entry xdg-mime validates a handler
# through: the entry has to be readable in a data dir and its Exec on PATH.
declare -A desktop_files=(
  [nautilus]="org.gnome.Nautilus.desktop"
  [nemo]="nemo.desktop"
  [dolphin]="org.kde.dolphin.desktop"
  [thunar]="thunar.desktop"
  [flea]="com.thisisgm.flea.desktop"
)
for file_manager in "${!desktop_files[@]}"; do
  printf '#!/bin/bash\nexit 0\n' >"$mock_bin/$file_manager"
  # Only Thunar's entry declares inode/directory: once the configured
  # handler's binary is gone, xdg-mime's fallback search then hands back
  # Thunar whatever else the machine running this has installed, which is
  # the entry point for the launcher's own fallback below.
  if [[ $file_manager == thunar ]]; then
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s %%U\nMimeType=inode/directory;\n' \
      "$file_manager" "$file_manager" >"$XDG_DATA_HOME/applications/${desktop_files[$file_manager]}"
  else
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s %%U\n' \
      "$file_manager" "$file_manager" >"$XDG_DATA_HOME/applications/${desktop_files[$file_manager]}"
  fi
done
chmod +x "$mock_bin"/*

# Every file manager registers for org.freedesktop.FileManager1 in the system
# data dirs; which one answers is the one the user's copy names.
for entry in "nautilus:/usr/bin/nautilus --gapplication-service" \
  "thunar:/usr/bin/Thunar --gapplication-service"; do
  cat >"$XDG_DATA_DIRS/dbus-1/services/${entry%%:*}.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.FileManager1
Exec=${entry#*:}
EOF
done
mv "$XDG_DATA_DIRS/dbus-1/services/thunar.service" \
  "$XDG_DATA_DIRS/dbus-1/services/org.xfce.Thunar.FileManager1.service"
mv "$XDG_DATA_DIRS/dbus-1/services/nautilus.service" \
  "$XDG_DATA_DIRS/dbus-1/services/org.freedesktop.FileManager1.service"

cat >"$XDG_CONFIG_HOME/mimeapps.list" <<'EOF'
[Default Applications]
inode/directory=org.kde.dolphin.desktop
EOF

[[ $(omarchy-default-file-manager) == "dolphin" ]] ||
  fail "default file manager is the installed handler in mimeapps.list" "$(omarchy-default-file-manager)"
pass "default file manager reads the inode/directory handler back as its name"

: >"$OMARCHY_TEST_NOTIFICATION_HISTORY"
omarchy-default-file-manager thunar
grep -qx "inode/directory=thunar.desktop" "$XDG_CONFIG_HOME/mimeapps.list" ||
  fail "setting the default records it in mimeapps.list" "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
[[ $(omarchy-default-file-manager) == "thunar" ]] ||
  fail "the new default reads back" "$(omarchy-default-file-manager)"

user_service="$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
[[ -f $user_service ]] ||
  fail "setting the default registers it for Show in folder"
grep -qx "Name=org.freedesktop.FileManager1" "$user_service" ||
  fail "the user registration answers the FileManager1 name" "$(cat "$user_service")"
grep -qx "Exec=/usr/bin/Thunar --gapplication-service" "$user_service" ||
  fail "the user registration is the chosen file manager's own, copied whole" "$(cat "$user_service")"
grep -q "omarchy-default-file-manager" "$user_service" ||
  fail "the user registration says where it came from"

mapfile -d '' -t notification <"$OMARCHY_TEST_NOTIFICATION_HISTORY"
[[ ${#notification[@]} == 3 && ${notification[2]} == "Thunar is now the default file manager" ]] ||
  fail "setting the default notifies with the chosen name" "argv: ${notification[*]}"
pass "setting the default writes mimeapps.list, the FileManager1 registration and a notification"

# `flea --default` rebinds the file-manager keys through a marked block in the
# user's bindings; choosing another file manager here has to take that block
# back out, leaving the picker block and the user's own bindings alone.
cat >"$HOME/.config/hypr/bindings.lua" <<'EOF'
o.bind("SUPER + E", "Mail", { launch = "mail" })
-- flea --default: begin. Written by `flea --default`; `flea --default off` removes the block whole.
hl.unbind("SUPER + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = 'flea --gui' })
-- flea --default: end
-- flea --picker: begin. Written by `flea --picker`.
o.window("com.thisisgm.flea.picker", { tag = "+floating-window" })
-- flea --picker: end
EOF
: >"$OMARCHY_TEST_HYPRCTL_LOG"
omarchy-default-file-manager nemo
grep -q "flea --default" "$HOME/.config/hypr/bindings.lua" &&
  fail "setting the default removes the block flea --default wrote"
grep -q "flea --picker: begin" "$HOME/.config/hypr/bindings.lua" ||
  fail "setting the default leaves flea --picker's block alone"
grep -q 'SUPER + E' "$HOME/.config/hypr/bindings.lua" ||
  fail "setting the default leaves the user's own bindings alone"
grep -qx "reload" "$OMARCHY_TEST_HYPRCTL_LOG" ||
  fail "removing the block reloads Hyprland" "$(cat "$OMARCHY_TEST_HYPRCTL_LOG")"
pass "setting the default takes back the keys flea --default bound"

# A file manager that is not installed yet installs first, in a terminal the
# user can give a password in, and only then becomes the default.
rm "$mock_bin/thunar"
: >"$OMARCHY_TEST_TERMINAL_LOG"
: >"$OMARCHY_TEST_NOTIFICATION_HISTORY"
omarchy-default-file-manager thunar
mapfile -d '' -t terminal <"$OMARCHY_TEST_TERMINAL_LOG"
[[ ${terminal[*]} == "omarchy-default-file-manager --install thunar" ]] ||
  fail "a missing file manager installation opens in a terminal" "argv: ${terminal[*]}"
grep -qx "inode/directory=nemo.desktop" "$XDG_CONFIG_HOME/mimeapps.list" ||
  fail "a missing file manager leaves the selection alone" "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
[[ ! -s $OMARCHY_TEST_NOTIFICATION_HISTORY ]] ||
  fail "a missing file manager skips notifications"
pass "a missing file manager waits for the install terminal"

: >"$OMARCHY_TEST_PKG_LOG"
omarchy-default-file-manager --install thunar
[[ $(<"$OMARCHY_TEST_PKG_LOG") == "thunar" ]] ||
  fail "installing installs the package" "$(cat "$OMARCHY_TEST_PKG_LOG")"
grep -qx "inode/directory=thunar.desktop" "$XDG_CONFIG_HOME/mimeapps.list" ||
  fail "installing makes it the default" "$(cat "$XDG_CONFIG_HOME/mimeapps.list")"
pass "installing a missing file manager makes it the default"

# The keys run whatever is the default, passing the directory the caller asked
# for, and fall back to a file manager the machine still has when the default
# package is gone.
cat >"$XDG_CONFIG_HOME/mimeapps.list" <<'EOF'
[Default Applications]
inode/directory=nemo.desktop
EOF
: >"$OMARCHY_TEST_LAUNCH_LOG"
omarchy-launch-file-manager "$test_tmp/some dir"
mapfile -d '' -t launch <"$OMARCHY_TEST_LAUNCH_LOG"
[[ ${#launch[@]} == 3 && ${launch[0]} == "--" && ${launch[1]} == "nemo" && ${launch[2]} == "$test_tmp/some dir" ]] ||
  fail "the launcher opens the default file manager on the given directory" "argv: ${launch[*]}"

rm "$mock_bin/nemo" "$mock_bin/dolphin" "$mock_bin/thunar" "$mock_bin/flea"
: >"$OMARCHY_TEST_LAUNCH_LOG"
omarchy-launch-file-manager-cwd
mapfile -d '' -t launch <"$OMARCHY_TEST_LAUNCH_LOG"
[[ ${#launch[@]} == 4 && ${launch[0]} == "--" && ${launch[1]} == "nautilus" &&
  ${launch[2]} == "--new-window" && ${launch[3]} == "$HOME" ]] ||
  fail "a default package that is gone falls back to the file manager installed" "argv: ${launch[*]}"
pass "the launcher runs the default and falls back when it is missing"
