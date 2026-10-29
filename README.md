# Save Explorer Windows

Saves the File Explorer windows and tabs you have open, so you can reopen them all after a restart, a crash or a mistake. It can do this by itself every hour, warns you when folders seem to have been lost, and shows what changed so you can reopen just those.

For Windows 11 (version 22H2 or newer, which has tabs in File Explorer). Nothing to install: it uses Windows PowerShell, which comes with Windows.

## Getting it

1. On this page, click **Code**, then **Download ZIP**.
2. Before unpacking, right-click the ZIP, choose **Properties**, tick **Unblock** at the bottom, and click **OK**. Otherwise Windows marks every file inside as from the internet, and PowerShell refuses to run them.
3. Unpack it into a folder you will keep, for example `Documents\Save Explorer Windows`. Not in Downloads: the automatic backups run the script from wherever it is, so it should stay put.
4. Keep the files together: the scripts all need `Explorer Windows Shared.psm1` and `Settings.ini` beside them.
5. Allow PowerShell scripts for your account, once. Windows does not allow them at first, and **Run with PowerShell** then opens a window that closes at once, before you can read why. Open **Windows PowerShell** from the Start menu and run:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

   This lets scripts on your own PC run, and downloaded ones once unblocked. It needs no administrator rights and changes nothing for other accounts. If you already unpacked without unblocking, right-click each `.ps1` file and unblock it the same way.

## Saving by hand

Right-click `Save Explorer Windows.ps1` and choose **Run with PowerShell**.

It asks for a label. Type a few words to recognise the save by, or just press Enter. A moment later it says where it saved: a file named like `Restore Explorer Session 2026.10.16 14-30-00_my label.ps1` in `Saved sessions\Manual saves`. Saves made by hand are never deleted.

## Automatic backups

Right-click `Set up automatic backups.ps1`, choose **Run with PowerShell**, and type **I** to install. It asks how often to save: press Enter for every hour, or type 10, 20 or 30 for minutes, or 2, 3, 4, 6, 8 or 12 for hours. It then offers to make one backup straight away, so you can see that it works.

From then on Windows saves your open folders on that schedule into `Saved sessions\Automatic backups`. The runs are counted from 00:50, so hourly runs fall at ten to every hour. It keeps enough backups to reach at least 48 hours back, however often it saves (`KeepBackups` in *Settings*). It only runs while you are signed in, and makes up for a backup it missed while the PC was off.

To stop it, or after moving the folder, run `Set up automatic backups.ps1` again: **U** updates it to the new place and lets you change how often it saves, **R** removes it. Your backups stay either way.

Run the setup normally, not "as administrator". If you do want to set it up by hand in Task Scheduler instead, `DOC.md` lists the exact settings.

## Reopening your folders

Right-click a `Restore Explorer Session ... .ps1` file and choose **Run with PowerShell**.

- Folders that are already open are skipped, so it is safe to run after only some were lost.
- Each window opens maximized, and its tabs are added one by one. Leave the keyboard alone until it says "Done": each new window takes the keyboard as it appears.
- Tabs come back in the order Windows lists them, which is usually, but not always, the order they had.
- To bring back only some folders, or to put them back beside tabs that are still open, use the compare window instead.

## The compare window

Right-click `Compare Explorer Backups.ps1` and choose **Run with PowerShell**. It shows two lists side by side, each one a saved session, or what is open right now. Pick them in the boxes above the lists: they hold every save, automatic and made by hand, newest first.

- Folders are grouped by the window they were in.
- **Red** on the left: in the left session but not the right. **Orange** on the right: in the right session but not the left. So with an older backup on the left and a newer one on the right, red is what got lost and orange is what is new.
- **Only windows with red or orange** hides the windows where nothing changed. A window with a change still shows all its tabs.
- **Show full paths** shows each folder's whole path, its own name included, instead of only the folder it is in.
- Both boxes stay as you left them the next time the window opens.
- Tick folders in either list and click **Open ticked**. Each one opens as a tab beside the tabs it used to be with, if any of those are open now; otherwise in a new window, which the rest of its old tabs then join. Folders already open are skipped.
- **Tick all missing** ticks every red folder.
- **Settings...** changes when the "folders lost?" warning appears, and how many backups are kept.

## The "folders lost?" warning

After an automatic backup, the compare window can open by itself, saying some folders that were open earlier are no longer open. It does when:

- the PC restarted, you signed out, or File Explorer crashed, and at least one folder did not come back, or
- many folders vanished at once without any of that: by default at least 3, and at least half of what was open.

The left list then shows the last backup from before the loss, with the lost folders in red. That backup is kept safe until you click **Mark as checked**. Tick the folders you want back and click **Open ticked**; if you closed them yourself, just click **Mark as checked**. The window stays on top until you have clicked into it and moved on.

## Good to know

- **Nothing is saved when no folder is open.** Closing all your folders counts as on purpose: no warning, and folders you open later are not compared with the ones from before. Your last full backup is not deleted because of this.
- **It waits after a restart.** For 5 minutes after you sign in, Windows is still reopening your folders, so a backup due in that time waits until they are back.
- **Old backups are cleaned up.** A new backup with exactly the same folders replaces the older one. Of the rest, enough are kept to reach 48 hours back: 48 when it saves every hour, 144 every 20 minutes. Saves made by hand are never cleaned up, and a backup kept for a "folders lost?" warning stays until you mark it as checked.
- **A frozen File Explorer window is skipped.** If a window stops responding, its tabs are left out after 2 seconds each, and the save lists what it could not read. If File Explorer is stuck entirely, nothing can be saved until it recovers. Don't end File Explorer in Task Manager to fix it: all your folder windows live in it and would close.
- **Your saves list your folders.** Every file in `Saved sessions` names the folders you had open, so treat them as private. A `.kopiaignore` file in each keeps them out of Kopia backups. If you sync this folder with Syncthing, add `Saved sessions` to its ignore list. Other backup or sync tools need telling separately.
- **Don't rename `Save Explorer Windows.ps1`.** The automatic backups look for it by name. If you move the folder, run the setup again.
- **What happened, and when:** `Saved sessions\Automatic backups\log.txt` has one line per automatic backup.
- **Run it as yourself, not as administrator.** An administrator window cannot see your folder windows, and saves nothing.

## Settings

Click **Settings...** in the compare window, or open `Settings.ini` in Notepad, change a value after the `=` sign, and save. The next automatic backup uses it.

| Setting | Default | What it does |
|---|---|---|
| `KeepBackups` | auto | How many automatic backups to keep: `auto` for 48 hours' worth at the chosen interval, or a number |
| `Warnings` | on | `off` turns the "folders lost?" warning off completely |
| `RestartMinFolders` | 1 | After a restart, sign-out or crash: how many folders must be missing for the warning |
| `DropWarnings` | on | `off`: no warning when folders vanish without a restart |
| `DropMinFolders` | 3 | ...how many folders must vanish at once |
| `DropMinPercent` | 50 | ...and what share of the open folders that must be |

## Removing it

Run `Set up automatic backups.ps1` and type **R**, then delete the folder.

## For the curious

`DOC.md` explains how it works inside. `Tests\Run tests.ps1` checks the rules for cleanup, the "folders lost?" warning and where reopened folders go, without touching your windows.

## Support

This is free and stays free. If it saved you time and you'd like to say thanks, a tip is welcome but never expected:

<a href="https://ko-fi.com/eepycoding"><img src=".github/support_me_on_kofi_blue.webp" alt="Support me on Ko-fi" width="245"></a>
