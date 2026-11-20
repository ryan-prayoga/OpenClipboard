use std::cell::RefCell;
use std::sync::Once;

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};

unsafe extern "C" {
    fn oc_shortcut_fired(identifier: u32);
}

struct Shortcut {
    manager: GlobalHotKeyManager,
    active: Option<HotKey>,
}

thread_local! {
    static SHORTCUT: RefCell<Option<Shortcut>> = const { RefCell::new(None) };
}

static EVENT_HANDLER: Once = Once::new();

#[unsafe(no_mangle)]
extern "C" fn oc_register_shortcut(key: u16, flags: u8) -> i64 {
    let Some(code) = key_code(key) else {
        return -2;
    };
    let mut modifiers = Modifiers::empty();
    modifiers.set(Modifiers::CONTROL, flags & 1 != 0);
    modifiers.set(Modifiers::ALT, flags & 2 != 0);
    modifiers.set(Modifiers::SHIFT, flags & 4 != 0);
    modifiers.set(Modifiers::META, flags & 8 != 0);
    if flags & 11 == 0 {
        return -2;
    }

    let next = HotKey::new(Some(modifiers), code);
    EVENT_HANDLER.call_once(|| {
        GlobalHotKeyEvent::set_event_handler(Some(|event: GlobalHotKeyEvent| {
            if event.state == HotKeyState::Pressed {
                unsafe { oc_shortcut_fired(event.id) };
            }
        }));
    });

    SHORTCUT.with_borrow_mut(|slot| {
        if slot.is_none() {
            let Ok(manager) = GlobalHotKeyManager::new() else {
                return -1;
            };
            *slot = Some(Shortcut {
                manager,
                active: None,
            });
        }
        let Some(shortcut) = slot else {
            return -1;
        };
        if shortcut.active == Some(next) {
            return i64::from(next.id());
        }
        if shortcut.manager.register(next).is_err() {
            return -1;
        }
        if let Some(previous) = shortcut.active
            && shortcut.manager.unregister(previous).is_err()
        {
            let _ = shortcut.manager.unregister(next);
            return -1;
        }
        shortcut.active = Some(next);
        i64::from(next.id())
    })
}

fn key_code(key: u16) -> Option<Code> {
    use Code::*;
    Some(match key {
        0 => KeyA,
        1 => KeyS,
        2 => KeyD,
        3 => KeyF,
        4 => KeyH,
        5 => KeyG,
        6 => KeyZ,
        7 => KeyX,
        8 => KeyC,
        9 => KeyV,
        11 => KeyB,
        12 => KeyQ,
        13 => KeyW,
        14 => KeyE,
        15 => KeyR,
        16 => KeyY,
        17 => KeyT,
        18 => Digit1,
        19 => Digit2,
        20 => Digit3,
        21 => Digit4,
        22 => Digit6,
        23 => Digit5,
        24 => Equal,
        25 => Digit9,
        26 => Digit7,
        27 => Minus,
        28 => Digit8,
        29 => Digit0,
        30 => BracketRight,
        31 => KeyO,
        32 => KeyU,
        33 => BracketLeft,
        34 => KeyI,
        35 => KeyP,
        36 => Enter,
        37 => KeyL,
        38 => KeyJ,
        39 => Quote,
        40 => KeyK,
        41 => Semicolon,
        42 => Backslash,
        43 => Comma,
        44 => Slash,
        45 => KeyN,
        46 => KeyM,
        47 => Period,
        48 => Tab,
        49 => Space,
        50 => Backquote,
        51 => Backspace,
        96 => F5,
        97 => F6,
        98 => F7,
        99 => F3,
        100 => F8,
        101 => F9,
        103 => F11,
        109 => F10,
        111 => F12,
        118 => F4,
        120 => F2,
        122 => F1,
        123 => ArrowLeft,
        124 => ArrowRight,
        125 => ArrowDown,
        126 => ArrowUp,
        _ => return None,
    })
}
