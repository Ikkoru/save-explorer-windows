# Save Explorer Windows

Saves the File Explorer windows and tabs you have open, so you can reopen them all after a restart, a crash or a mistake. It can do this by itself every two hours, and warns you when folders seem to have been lost.

For Windows 11 (version 22H2 or newer, which has tabs in File Explorer). Nothing to install: it uses Windows PowerShell, which comes with Windows.

## Getting it

1. On this page, click **Code**, then **Download ZIP**.
2. Unpack it into a folder you will keep, for example `Documents\Save Explorer Windows`. Not in Downloads: the automatic backups run the script from wherever it is, so it should stay put.
3. Keep the files together. `Save Explorer Windows.ps1`, `Explorer Windows Shared.psm1` and `Settings.ini` need each other.

If Windows refuses to run a file because it came from the internet: right-click it, choose **Properties**, tick **Unblock** at the bottom, and click **OK**.

## Saving by hand

Right-click `Save Explorer Windows.ps1` and choose **Run with PowerShell**.

It asks for a label. Type a few words to recognise the save by, or just press Enter. A moment later it says where it saved: a file named like `Restore Explorer Session 2026.10.16 14-30-00_my label.ps1` in `Saved sessions\Manual saves`. Saves made by hand are never deleted.

## Automatic backups every two hours

Right-click `Set up automatic backups.ps1`, choose **Run with PowerShell**, and type **I** to install. It offers to make one backup straight away, so you can see that it works.

From then on Windows saves your open folders every two hours, at ten to every odd hour, into `Saved sessions\Automatic backups`. It only runs while you are signed in, and makes up for a backup it missed while the PC was off.

To stop it, or after moving the folder, run `Set up automatic backups.ps1` again: **U** updates it to the new place, **R** removes it. Your backups stay either way.

Run the setup normally, not "as administrator". If you do want to set it up by hand in Task Scheduler instead, `DOC.md` lists the exact settings.

## Reopening your folders

Right-click a `Restore Explorer Session ... .ps1` file and choose **Run with PowerShell**.

- Folders that are already open are skipped, so it is safe to run after only some were lost.
- Each window opens maximized, and its tabs are added one by one. **Don't use the keyboard or mouse until it says "Done"**: it opens tabs by pressing Ctrl+T for you, and a click elsewhere can send that keypress to the wrong window.
- If you type in Japanese, Chinese or Korean, switch the input method to plain English letters first, or it can swallow that keypress.
- Tabs come back in the order Windows lists them, which is usually, but not always, the order they had.

## The "folders lost?" message

After an automatic backup, a message can appear saying some folders that were open earlier are no longer open. It appears when:

- the PC restarted, you signed out, or File Explorer crashed, and at least one folder did not come back, or
- many folders vanished at once without any of that: by default at least 3, and at least half of what was open.

The backup from before the loss is kept safe until you answer. **Yes** (you closed them yourself) lets it be cleaned up later like any other. **No** keeps it and shows it in File Explorer, so you can run it to reopen what is missing.

## Good to know

- **Nothing is saved when no folder is open.** Closing all your folders counts as on purpose: no message, and folders you open later are not compared with the ones from before. Your last full backup is not deleted because of this.
- **It waits after a restart.** For 5 minutes after you sign in, Windows is still reopening your folders, so a backup due in that time waits until they are back.
- **Old backups are cleaned up.** A new backup with exactly the same folders replaces the older one. Of the rest, the newest 20 are kept. Saves made by hand are never cleaned up, and a backup kept for a "folders lost?" message stays until you answer it.
- **A frozen File Explorer window is skipped.** If a window stops responding, its tabs are left out after 2 seconds each, and the save lists what it could not read. If File Explorer is stuck entirely, nothing can be saved until it recovers. Don't end File Explorer in Task Manager to fix it: all your folder windows live in it and would close.
- **Your saves list your folders.** Every file in `Saved sessions` names the folders you had open, so treat them as private. A `.kopiaignore` file in each keeps them out of Kopia backups. If you sync this folder with Syncthing, add `Saved sessions` to its ignore list. Other backup or sync tools need telling separately.
- **Don't rename `Save Explorer Windows.ps1`.** The automatic backups look for it by name. If you move the folder, run the setup again.
- **What happened, and when:** `Saved sessions\Automatic backups\log.txt` has one line per automatic backup.
- **Run it as yourself, not as administrator.** An administrator window cannot see your folder windows, and saves nothing.

## Settings

Open `Settings.ini` in Notepad, change a value after the `=` sign, and save. The next automatic backup uses it.

| Setting | Default | What it does |
|---|---|---|
| `KeepBackups` | 20 | How many automatic backups to keep |
| `Warnings` | on | `off` turns the "folders lost?" message off completely |
| `RestartMinFolders` | 1 | After a restart, sign-out or crash: how many folders must be missing for the message |
| `DropWarnings` | on | `off`: no message when folders vanish without a restart |
| `DropMinFolders` | 3 | ...how many folders must vanish at once |
| `DropMinPercent` | 50 | ...and what share of the open folders that must be |

## Removing it

Run `Set up automatic backups.ps1` and type **R**, then delete the folder.

## For the curious

`DOC.md` explains how it works inside. `Tests\Run tests.ps1` checks the rules for cleanup and the "folders lost?" message without touching your windows.
