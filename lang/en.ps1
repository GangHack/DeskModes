<#
    lang\en.ps1 - the interface in English, and the file every other language is laid over.

    A key that is missing from a translation falls back to the text here, so this file is the
    only one that has to be complete. Adding a string means adding it HERE first: tools\check.ps1
    walks the other files against this one and fails on a key that exists nowhere else.

    In the markup a string is a %%T:key%% token (Expand-UiText in SettingsDialog.ps1); in code it
    is Get-Text. Nothing in the log goes through either - the log stays English whatever the
    window speaks, because it is read against greps, commits and issues.

    _name    what this language calls itself, for the drop-down on the Behavior page.
    _plural  which of the forms below a count wants. English has two, Russian three.

    A value with {0} in it is a -f template. The word order inside it belongs to the language:
    a translation is free to move the pieces, and several of these are written out per case
    rather than glued together precisely because Russian cannot fill an English hole.
#>

@{
    '_name'   = 'English'
    # 1 file, 2 files. The zero case takes the plural here, as English does.
    '_plural' = { param([int]$n) if ($n -eq 1) { 0 } else { 1 } }

    'win.settings'                = 'DeskModes - Settings'
    'win.mode'                    = 'DeskModes - Mode'
    'win.rule'                    = 'DeskModes - Rule'
    'win.timer'                   = 'DeskModes - Timer'

    'desk.taskbar'                = 'Taskbar'
    'desk.taskbar.saved'          = 'Taskbar on switch'

    'nav.desk'                    = 'Your desk'
    'nav.modes'                   = 'Modes'
    'nav.rules'                   = 'Rules'
    'nav.behavior'                = 'Behavior'
    'nav.diary'                   = 'Diary'
    'nav.about'                   = 'About'

    'desk.hint'                   = 'Windows'' live layout and the choices DeskModes uses when switching are shown separately.'
    'desk.live'                   = 'Live in Windows'
    'desk.live.hint'              = 'Refreshes automatically. Positions, orientation and the starred taskbar display come from Windows.'
    'desk.live.unavailable'       = 'Windows did not report a display layout.'
    'desk.saved'                  = 'Configured for switching'
    # The two halves of the fold's own caption. Two diagrams of the same desk, one above the
    # other, is the question this page kept being asked: which of these is real? The second one
    # is folded away until it means something, and says which of the two it is either way.
    'desk.saved.off'              = 'Not customised - switching keeps the Windows layout above.'
    'desk.saved.on'               = 'Customised - switching uses this order and this taskbar display.'
    'desk.saved.hint'             = 'Drag the cards into the order the monitors really stand in, and star the one that keeps the taskbar.'
    'desk.whichIsWhich'           = 'Which is which'
    'desk.whichIsWhich.tip'       = 'Show each display''s name on it for a moment.'
    'desk.copy'                   = 'Use Windows layout'
    'desk.copy.tip'               = 'Uses Windows'' current order and taskbar display for switching, and remembers the complete arrangement as this desk''s baseline.'
    'desk.copy.failed'            = 'The Windows layout could not be saved. Nothing in this window was changed.'
    'desk.apply.hint'             = 'Applies only to the displays that are on now. Saving alone never changes them.'
    'desk.saveApplyNow'           = 'Save and apply now'
    'desk.saveApplyNow.tip'       = 'Save settings, then apply them to the displays active now.'
    'desk.apply.done'             = 'Settings saved and applied to the current desktop.'
    'desk.apply.failed'           = 'Windows refused this display arrangement. Try again when the displays are ready.'
    'desk.apply.recovery'         = 'The desktop changed but could not be verified. Use Windows layout to adopt what is visible, then try again.'
    'desk.apply.savedButFailed'   = 'Settings were saved, but this desktop could not be applied: {0}'
    'desk.apply.savedButPersistFailed' = 'Settings were saved and the desktop changed, but its verified snapshot could not be saved: {0}'
    'desk.apply.persistFailed'    = 'The desktop changed, but its verified snapshot could not be saved. Check the log before trying again.'
    'desk.apply.busy'             = 'Another display change is in progress. Try again in a moment.'
    'desk.apply.unavailable'      = 'Windows did not report a complete active desktop. Try again when the displays are ready.'
    'desk.apply.unverified'       = 'The desktop changed but could not be verified. Use Windows layout to adopt what is visible, then try again.'
    'desk.apply.primaryInactive'  = 'The selected taskbar display ({0}) is inactive or disconnected. Choose an active display and try again.'
    'desk.apply.invalid'          = 'These desk choices could not be turned into an exact display arrangement. Nothing was changed.'
    'desk.apply.changed'          = 'The active displays changed while preparing the apply. Nothing was changed; try again.'
    'desk.modeOverride'           = 'Current mode “{0}” has its own taskbar choice, which takes precedence during mode switching.'

    'displays.heading'            = 'Displays'

    'desk.table.hint'             = 'What each one reports about itself. The Monitor ID is the name settings.json and the log use.'
    'desk.sleep'                  = 'Displays go to sleep after'
    'desk.sleep.hint'             = 'Windows'' own setting, for when the computer is plugged in. Changed on Save.'

    'modes.hint'                  = 'A mode for each display is made for you. Add your own for a set of two or more; Edit opens the one place each is set up.'
    'modes.add'                   = 'Add a mode'

    'rules.hint'                  = 'Switch by itself when something happens; switch by hand and the rule lets go.'
    'rules.add'                   = 'Add a rule'

    'behavior.hint'               = 'What DeskModes does on its own.'
    'behavior.dayToDay'           = 'Day to day'
    'behavior.startup'            = 'Start with Windows'
    'behavior.startup.hint'       = 'The tray icon and the shortcuts come back after a reboot.'
    'settings.startupFailed'      = 'Settings were saved, but Start with Windows could not be changed. Try again or check the Startup folder; details are in the log.'
    'settings.writeFailed'        = 'Could not write settings.json - nothing was saved. Check that the folder DeskModes sits in can be written to; details are in the log.'
    'settings.sleepFailed'        = 'Windows would not change when the displays go dark. Everything else was saved. Set it in Settings - System - Power; details are in the log.'
    'settings.applyFailed'        = 'Settings were saved, but the running tray could not apply them. Close and restart DeskModes; details are in the log.'
    # A plain Save used to leave the window looking exactly as it did before it - the only answer
    # was a balloon behind the window somebody was still looking at, and the question it left was
    # always the same one: did that change my screens?
    'settings.savedOnly'          = 'Settings saved. The displays that are on were not changed.'
    'behavior.notifications'      = 'Notifications'
    'behavior.notifications.hint' = 'Show a notification after switching.'
    'behavior.back'               = 'Back to the previous mode'
    'behavior.back.hint'          = 'A shortcut that returns to the mode you left. The tray menu has it too, named after where it goes.'

    'hotkey.clear'                = 'Remove this shortcut'

    'behavior.windows'            = 'Remember window positions'
    'behavior.windows.hint'       = 'Bring windows back where they were, separately for every display set.'
    'behavior.lastMode'           = 'Restore the last mode at startup'
    'behavior.lastMode.hint'      = 'Replace the screens active at startup with the last mode you chose. Off by default.'
    'behavior.diary'              = 'Keep a diary'
    'behavior.diary.hint'         = 'Local only · No window titles · Delete activity.json to forget everything.'
    'behavior.reapply'            = 'When Windows rearranges the desk'
    'behavior.refresh'            = 'Best refresh rate'
    'behavior.refresh.hint'       = 'Put every display back to its maximum refresh rate when Windows silently drops it.'
    'behavior.onResume'           = 'Rebuild after waking from sleep'
    'behavior.onUnplug'           = 'Rebuild when a display is unplugged'
    'behavior.onPlug'             = 'When a display is plugged in, switch to'
    'behavior.onPlug.hint'        = 'Only when the display that appeared belongs to that mode.'

    'diary.page'                  = 'Open as a page'
    'diary.page.tip'              = 'Write the same report to stats.html and open it - a file you can keep or send.'
    'diary.timeOfDay'             = 'Time of day'
    'diary.apps'                  = 'Apps'
    'diary.appOnDisplay'          = 'App on display'

    # The first card of the About page. It is where a person looks for "how does this work" once
    # the tray icon is no longer new, so the tour and the reference stand above the version.
    'about.help'                      = 'Help'
    'about.help.hint'                 = 'How it works, and where to read the rest.'
    'about.welcome'                   = 'First steps'
    'about.welcome.hint'              = 'The four screens that opened on the first run.'
    'about.welcome.show'              = 'Show again'
    'about.reference'                 = 'Full reference'
    'about.reference.hint'            = 'Every setting, the command line and the troubleshooting, on the project page.'

    'about.diagnostics'               = 'Diagnostic summary'
    'about.diagnostics.hint'          = 'Display snapshot from when Settings opened. Includes versions and display modes; excludes settings and the diary.'
    'about.diagnostics.copy'          = 'Copy diagnostics'
    'about.folder'                    = 'Portable scripts. Disable Start with Windows and exit before deleting the folder.'

    'common.copy'                 = 'Copy'

    'about.copy.tip'              = 'Copy the version line - it is the first thing a bug report needs.'
    'about.project'               = 'Project page'
    'about.project.hint'          = 'Source, releases and the changelog on GitHub.'

    'common.open'                 = 'Open'

    'about.trouble'               = 'Something went wrong?'
    'about.trouble.hint'          = 'The log has every switch with its timing. Attach it to an issue.'
    'about.openLog'               = 'Open the log'
    'about.report'                = 'Report a problem'
    'about.where'                 = 'Where everything lives'
    'about.where.hint'            = 'settings.json, the diary and the log sit next to the program.'
    'about.openFolder'            = 'Open the folder'
    'about.support'               = 'Support DeskModes'
    'about.support.hint'          = 'Free and open, and it stays that way. If it saved you an evening, you can buy the author a coffee.'
    'about.donate'                = 'Donate'
    'about.donate.tip'            = 'Opens the donation page in your browser.'

    'common.save'                 = 'Save'
    'common.save.tip'             = 'Save settings without changing displays.'
    'common.cancel'               = 'Cancel'

    'editor.mode'                 = 'Mode'
    'editor.name'                 = 'Name'
    'editor.displays.hint'        = 'Tick every display this mode switches on.'
    'editor.taskbar.hint'         = 'Which display keeps the taskbar while this mode is on.'
    'editor.shortcut'             = 'Shortcut'
    'editor.shortcut.hint'        = 'Optional - the mode still works from the tray; click the box and press Ctrl, Alt, Shift or Win plus another key.'
    'editor.more'                 = 'Brightness, sound and commands'
    'editor.brightness'           = 'Brightness'
    'editor.ask'                  = 'Ask the monitors'
    'editor.brightness.hint'      = 'Set brightness with this mode. "Ask the monitors" walks the cable once and says which of yours answer - for brightness and contrast both.'
    'editor.contrast'             = 'Contrast'
    'editor.contrast.hint'        = 'The same, down the same channel in the cable. Fewer monitors answer for contrast than for brightness.'
    'editor.picture'              = 'Picture preset'
    'editor.picture.hint'         = 'Set the monitor the way you want it for this mode with its own buttons, then press Remember.'
    'editor.hdr'                  = 'HDR'
    'editor.hdr.hint'             = 'Turn HDR on or off when this mode comes on. A display that cannot do HDR is left as it is.'
    'editor.audio'                = 'Playback device'
    'editor.audio.hint'           = 'Make this the default output when the mode comes on. Part of the name is enough; empty leaves the sound alone.'
    'editor.hooks'                = 'Commands'
    'editor.hooks.hint'           = 'Run something around the switch. The command is started and not waited for - switching never hangs on it.'
    'editor.before'               = 'Before switching'
    'editor.after'                = 'After switching'

    'rule.heading'                = 'Rule'
    'rule.hint'                   = 'While the condition holds, the desk stays in that mode. Switch by hand and the rule lets go until the condition comes round again.'
    'rule.when'                   = 'When'
    'rule.process'                = 'Programs'
    'rule.process.hint'           = 'While any of these is running. Choose a program or type its process name, with or without .exe.'
    'rule.addProcess'             = 'Add program'
    'rule.backPrevious'           = 'back to the previous mode'
    'reason.processes'            = 'one of {0} is running'
    'rule.idle'                   = 'Idle for'
    'rule.idle.hint'              = 'Minutes with nobody at the keyboard or the mouse.'
    'rule.displays'               = 'Connected displays'
    'rule.displays.hint'          = 'Exactly these, and no others. Connected is enough - one that is switched off still counts.'
    'rule.mode'                   = 'Switch to'
    'rule.back'                   = 'Go back to'
    'rule.back.hint'              = 'Where the desk goes when the condition ends.'

    # --- what a mode is called ---
    # The key stays 'solo:<name>' whatever this says; nothing is ever looked up by title.
    'mode.solo'                   = 'Only {0}'
    'mode.all'                    = 'All displays'

    # --- what a switch answers ---
    'switch.busy'                 = 'A switch is already in progress.'
    'switch.notConnected'         = 'That display is not connected right now.'
    'switch.noCombo'              = 'The mode ''{0}'' no longer exists in the settings.'
    'switch.unknownMode'          = 'Unknown mode ''{0}''.'
    'switch.noMembers'            = 'Mode ''{0}'': none of its displays are connected. Nothing was turned off, so you keep a picture.'
    'switch.refused'              = 'Windows refused the display configuration for ''{0}''. Nothing was changed, so you keep a picture.'
    'switch.snapshotWriteFailed'  = 'The current desktop could not be saved, so no displays were changed.'
    'switch.noneCameUp'           = 'None of the displays of ''{0}'' came up, so the previous set was put back. Check the cable and Deep Sleep Mode in the monitor''s menu.'
    'verdict.failed'              = 'did not come up: {0} - unplug the cable and plug it back in'
    'verdict.refused'             = 'Still on: {0} - Windows would not turn them off'
    'verdict.layout'              = 'positions not arranged - Windows refused the layout, press the hotkey to retry'
    'verdict.restore'             = 'desktop not fully restored - Windows changed part of the display arrangement, press the hotkey to retry'

    # --- how long ---
    # Read back by ConvertFrom-DurationText, so whatever abbreviation a language picks here has to
    # appear in unit.parse.* below as well, or the timer box stops understanding what it wrote.
    'unit.seconds'                = '{0} s'
    'unit.minutes'                = '{0} min'
    'unit.hours'                  = '{0} h'
    'unit.hoursMinutes'           = '{0} h {1} min'
    'unit.hoursMinutesPadded'     = '{0} h {1:00} min'
    # Extra spellings the timer box accepts, each one preceded by a pipe. English is built into the
    # pattern already, so there is nothing to add here.
    'unit.parse.hours'            = ''
    'unit.parse.minutes'          = ''
    'sleep.never'                 = 'Never'

    # --- what a rule is waiting for, in a window ---
    'reason.process'              = '{0} is running'
    'reason.idle'                 = 'nobody at the computer for {0}'
    'reason.oneDisplay'           = '{0} is the only display'
    'reason.displays'             = '{0} are connected'

    # --- words the whole interface shares ---
    'common.close'                = 'Close'
    'common.edit'                 = 'Edit'
    'common.remove'               = 'Remove'
    'noun.brightness'             = 'brightness'
    'noun.contrast'               = 'contrast'

    # --- a display, in a row or on a card ---
    'display.off'                 = 'off'
    'display.notConnected'        = 'not connected'
    'display.resolution'          = '{0} x {1} @ {2} Hz'
    # The star beside it says what it is; this is the word next to the star.
    'desk.taskbar.lower'          = 'taskbar'
    'desk.card.remembered'        = '{0} is remembered from your settings and keeps its place in the row. Plug it back in and it comes to life.'
    'desk.sleep.unknown'          = 'Windows would not say. Change it in Settings - System - Power.'

    # --- the language row ---
    'behavior.language'           = 'Language'
    'behavior.language.hint'      = 'Save refreshes Settings in the selected language automatically. The log stays English.'
    'behavior.language.auto'      = 'Follow Windows'

    # --- the shortcut field ---
    'hotkey.none'                 = 'no shortcut'
    'hotkey.press'                = 'press the keys'
    'hotkey.needsMods'            = 'needs Ctrl / Alt / Shift'
    'hotkey.unsupported'          = 'unsupported key'

    # --- the modes list ---
    'modes.allSub'                = 'Every connected display'
    'modes.orphanSub'             = 'Gone from your desk - what was set for it is kept until you remove it'
    'summary.level'               = '{0} {1}'
    'summary.levelEach'           = '{0} per display'
    'summary.picture'             = 'picture'
    'summary.pictureOn'           = 'picture on {0} display', 'picture on {0} displays'
    # What was cut off the end of a row's caption. Three facts fit and read; the fourth used to
    # arrive as "cont..." - half a word, which reads as a rendering fault rather than as a list
    # that goes on. The full truth is in the tooltip and behind Edit.
    'summary.more'                = '+{0}'
    'summary.hdr'                 = 'HDR'
    'summary.audio'               = 'audio'
    'summary.hook'                = 'command'

    # --- the mode editor ---
    'editor.comboHint'            = 'A named set of displays with its own tray entry, optional shortcut and brightness.'
    'editor.usualRules'           = 'Follow the usual rules'
    'editor.tickFirst'            = 'Tick a display first.'
    'editor.needName'             = 'Give the mode a name - it becomes its menu entry.'
    'editor.nameTaken'            = 'A mode called ''{0}'' already exists.'
    'editor.needDisplay'          = 'Tick at least one display.'
    'editor.taskbarMember'        = 'The taskbar display must be one of the ticked displays.'
    'editor.hotkeyTaken'          = '{0} already drives ''{1}''. One shortcut can only drive one mode.'
    'settings.hotkeyDuplicate'    = '{0} is assigned twice. One shortcut can only drive one mode.'
    'level.none'                  = 'leave the {0} alone'
    'level.one'                   = 'one level for every display of this mode'
    'level.each'                  = 'a level for each display'

    # --- asking the monitors over the cable ---
    'probe.asking'                = 'asking...'
    'probe.failed'                = 'could not ask the monitors - {0}'
    'probe.brightness'            = 'brightness {0}'
    'probe.contrast'              = 'contrast {0}'
    'probe.answers'               = 'answers: {0}'
    'probe.noAnswer'              = 'no answer: {0}'
    'probe.nobody'                = 'nobody answered - only displays that are ON can be asked'
    'probe.sleeping'              = 'Sleeping displays cannot be asked.'

    # --- the picture preset ---
    'picture.remembered'          = 'Remembered'
    'picture.notRemembered'       = 'Not remembered'
    'picture.remember'            = 'Remember'
    'picture.update'              = 'Update'
    'picture.forget'              = 'Forget'
    'picture.noDisplay'           = 'This mode has no display to remember one for.'
    'picture.notOnDesk'           = '{0} is not on the desk right now.'
    'picture.noAnswer'            = '{0} did not answer. Is it on, and is DDC/CI on in its menu?'
    'picture.done'                = '{0} remembered as it looks now.'

    # --- HDR ---
    'hdr.leaveAlone'              = 'Leave alone'
    'hdr.on'                      = 'On'
    'hdr.off'                     = 'Off'
    'hdr.noDisplay'               = 'This mode has no display to set it on.'

    # --- the rules ---
    'rules.empty'                 = 'Nothing yet - the desk changes only when you say so.'
    'rule.when.process'           = 'a program is running'
    'rule.when.idle'              = 'nobody is at the computer'
    'rule.when.displays'          = 'these displays are connected'
    'rule.nowhere'                = 'nowhere'
    'rule.backTo'                 = 'back to {0}'
    'rule.needMode'               = 'Choose the mode this rule switches to.'
    'rule.needProcess'            = 'Name the program to watch for - "cs2" or "cs2.exe", as it appears in Task Manager.'
    'rule.needMinutes'            = 'Give the idle time in whole minutes, at least one.'
    'rule.needDisplays'           = 'Tick the displays that make up this desk - at least one.'
    'rule.backIsMode'             = 'A rule cannot go back to the mode it switches to. Leave it as "wherever the desk was".'
    'behavior.onPlug.nothing'     = 'do nothing'
    'about.donate.none'           = 'There is no address yet - the button lights up when there is one.'

    # --- the diary ---
    'diary.today'                 = 'Today'
    'diary.all'                   = 'All'
    'diary.days'                  = '{0} day', '{0} days'
    'diary.empty'                 = 'Nothing counted for this period yet.'
    'diary.nothingYet'            = 'nothing yet'
    'diary.rangeTitle'            = '{0} .. {1}, and {2} of those days have something in them'
    'diary.card.active'           = 'at the computer'
    'diary.card.average'          = 'a day on average'
    'diary.card.longest'          = 'longest session'
    'diary.card.switches'         = 'mode switches'
    'diary.card.usualDay'         = 'usual day'
    'diary.card.streak'           = 'days in a row'
    'diary.pageTitle'             = 'DeskModes - diary'
    'diary.footer'                = 'Window titles are never recorded - only process names. Delete activity.json to forget everything.'
    'diary.pageFailed'            = 'Could not write stats.html.'
    'diary.pageFailedHint'        = 'Check that the folder DeskModes sits in can be written to. Details are in the log.'

    # --- the tray icon and its menu ---
    'tray.switching'              = 'switching...'
    'menu.displays'               = 'DISPLAYS'
    'menu.switchTo'               = 'SWITCH TO'
    'menu.primary'                = 'primary'
    'menu.notConnected'           = '(not connected)'
    'menu.belowHz'                = '(below {0} Hz)'
    'menu.whichIsWhich'           = 'Which is which...'
    'menu.backTo'                 = 'Back to {0}'
    'menu.welcome'                = 'First steps...'
    'menu.statistics'             = 'Statistics...'
    'menu.statisticsOff'          = 'Statistics (diary is off)'
    'menu.settings'               = 'Settings...'
    'menu.openLog'                = 'Open log'
    'menu.openFolder'             = 'Open folder'
    'menu.about'                  = 'About {0}'
    'menu.exit'                   = 'Exit'

    # --- the timer ---
    # A key per action, and no ready-made "shutdown"/"sleep" dropped into a hole: those are
    # verbs, and a language that declines them cannot take one from somewhere else.
    'menu.timer.in.shutdown'      = 'Shut down in...'
    'menu.timer.in.sleep'         = 'Sleep in...'
    'menu.timer.armed.shutdown'   = 'Shut down in {0}'
    'menu.timer.armed.sleep'      = 'Sleep in {0}'
    'menu.timer.add'              = 'Add {0} minute', 'Add {0} minutes'
    'menu.timer.take'             = 'Take {0} minute off', 'Take {0} minutes off'
    'menu.timer.cancel'           = 'Cancel the timer'
    'menu.timer.pick'             = 'Pick a time...'
    'tray.timer.shutdown'         = 'shutting down in {0}'
    'tray.timer.sleep'            = 'sleeping in {0}'
    'timer.at'                    = 'at {0}'
    'timer.tomorrow'              = 'tomorrow'
    'timer.hint'                  = 'minutes, or 1h30 - up to {0}'
    'timer.set'                   = 'Timer set'
    'timer.set.shutdown'          = 'The computer will shut down in {0}, {1}. Cancel it from this menu.'
    'timer.set.sleep'             = 'The computer will go to sleep in {0}, {1}. Cancel it from this menu.'
    'timer.moved'                 = 'Timer moved'
    'timer.moved.shutdown'        = 'The computer will shut down in {0}, {1}.'
    'timer.moved.sleep'           = 'The computer will go to sleep in {0}, {1}.'
    'timer.cancelled'             = 'Timer cancelled'
    'timer.cancelled.body'        = 'The computer stays on.'
    'timer.lastMinute'            = 'One minute left'
    'timer.lastMinute.shutdown'   = 'The computer will shut down in a minute. Cancel it from the tray menu.'
    'timer.lastMinute.sleep'      = 'The computer will go to sleep in a minute. Cancel it from the tray menu.'

    # --- the notifications ---
    'balloon.switched'            = 'Displays switched'
    'balloon.partial'             = 'Switched with problems'
    'balloon.skipped'             = 'Skipped'
    'balloon.failed'              = 'Failed'
    'balloon.nothingUp'           = 'Nothing came up'
    'balloon.nothingUp.body'      = 'None of that mode''s displays responded. Check the cable and Deep Sleep Mode in the monitor''s menu.'
    'balloon.noBack'              = 'Nothing to go back to'
    'balloon.noBack.body'         = 'No mode has been left yet in this folder.'
    'balloon.refresh'             = 'Refresh rate restored'
    'balloon.refresh.body'        = '{0} - Windows had dropped it.'
    'balloon.hotkeysTaken'        = 'Some shortcuts are taken'
    'balloon.hotkeysTaken.body'   = '{0} - another program already holds these. Those modes still work from the tray menu.'
    'balloon.saved'               = 'Settings saved'
    'balloon.saved.body'          = 'Shortcuts reloaded.'
    'balloon.diaryOff'            = 'The diary is off'
    'balloon.diaryOff.body'       = 'Turn on "Keep a diary" in Settings, and statistics appear as the day goes.'
    'balloon.welcomeFailed'       = 'Could not open the first steps'
    'balloon.diaryFailed'         = 'Could not open the diary'
    'balloon.timerFailed'         = 'Could not open the timer'
    'balloon.seeLog'              = 'Details are in the log.'
    'balloon.noLog'               = 'No log yet'
    'balloon.noLog.body'          = 'It appears after the first switch.'
    'balloon.firstRun'            = 'Double-click the icon for Settings; right-click for the display menu.'

    # --- the displays table on the desk page ---
    'table.display'               = 'Display'
    'table.size'                  = 'Size'
    'table.native'                = 'Native'
    'table.now'                   = 'Now'
    'table.forget'                = 'Forget'
    'table.forget.tip'            = 'Take this display out of the lists. It comes back by itself if you plug it in again; what a mode or a rule set for it stays under Modes until you remove it there.'

    'rule.whereverWas'            = 'wherever the desk was'

    'editor.combo'                = 'Mode'
    'editor.newCombo'             = 'New mode'
    'editor.allHint'              = 'Every display at once, with its own shortcut and brightness.'
    'editor.soloHint'             = 'One display on and the rest off, with its own shortcut and brightness.'

    'timer.caption.shutdown'      = 'SHUT DOWN IN'
    'timer.caption.sleep'         = 'SLEEP IN'
    'timer.start.shutdown'        = 'Shut down'
    'timer.start.sleep'           = 'Sleep'

    # --- the first steps --------------------------------------------------------
    # Four screens on the first run, and the same four from the tray menu and from About
    # afterwards. Two of them name the person's OWN desk - the monitors found and the shortcuts
    # just handed out - because a tour that says "your displays" in general is clicked through.
    'win.welcome'                 = 'DeskModes - First steps'
    'welcome.step'                = 'Step {0} of {1}'
    'welcome.back'                = 'Back'
    'welcome.next'                = 'Next'
    'welcome.skip'                = 'Skip'
    'welcome.setup'               = 'Set up my desk'
    'welcome.done'                = 'Done'
    'welcome.language.tip'        = 'The language of the windows, the menu and the notifications. It follows Windows until you change it, here or later in Behavior. The log stays English.'

    'welcome.1.title'             = 'Your screens, in named sets'
    'welcome.1.body'              = 'A mode is a set of displays with a name of your own: Work on two screens, Game on one, Movie on the TV. Switching to it turns those displays on, turns the rest off and puts the desktop back the way you had it.'
    'welcome.1.desk'              = 'On your desk right now: {0}.'
    'welcome.1.deskNone'          = 'Windows has not named a display yet. Your desk appears in Settings as soon as it does.'
    'welcome.1.portable'          = 'Nothing was installed. DeskModes is the folder you unpacked, and deleting that folder removes it.'

    'welcome.2.title'             = 'It lives next to the clock'
    'welcome.2.menu'              = 'Right-click the tray icon for the list of modes - that menu is how you switch.'
    'welcome.2.settings'          = 'Double-click the same icon to open Settings. A single click only selects it, as it does for every tray icon.'
    'welcome.2.hidden'            = 'Cannot see the icon? Windows hides new ones: open the ^ arrow at the left of the tray and drag DeskModes out onto the taskbar.'

    'welcome.3.title'             = 'The shortcuts are ready'
    'welcome.3.body'              = 'This first run gave each mode a shortcut. Change or clear any of them under Modes; a mode without one still switches from the tray menu.'
    'welcome.3.none'              = 'There was no mode to give one to yet. Add a mode under Modes and give it a shortcut there.'
    'welcome.3.more'              = 'and {0} more', 'and {0} more'
    'welcome.3.taken'             = 'A shortcut another program already holds is refused by Windows. DeskModes says which ones, and those modes keep working from the menu.'

    'welcome.4.title'             = 'If a screen stays dark'
    'welcome.4.safety'            = 'Nothing changes unless Windows accepts the whole arrangement. If none of a mode''s displays comes up, the previous set is put back by itself, so you keep a picture.'
    'welcome.4.back'              = 'Give "Back to the previous mode" a shortcut in Behavior before you experiment. It returns the desk to where you just were.'
    'welcome.4.help'              = 'About holds the log, the diagnostics for a bug report, the full reference and these four screens again.'
}
