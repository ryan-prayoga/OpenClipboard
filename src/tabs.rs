//! Pure helpers for the collection tab strip. Tab 0 is the history tab and tabs
//! 1..count are the user collections, so `count` is always collections + 1.

/// Index after moving `delta` tabs from `current`, clamped to the existing tabs.
pub fn step(current: i64, count: i64, delta: i64) -> i64 {
    if count <= 1 {
        return 0;
    }
    current.saturating_add(delta).clamp(0, count - 1)
}

/// Tab index for the ⌘1…⌘9 shortcut, or -1 when there is no such tab.
pub fn for_digit(digit: i64, count: i64) -> i64 {
    if (1..=9).contains(&digit) && digit <= count {
        digit - 1
    } else {
        -1
    }
}

/// Stable hue in `[0, 1)` for a collection's colour dot. Golden-ratio steps keep
/// neighbouring ids visually apart.
pub fn hue(id: i64) -> f64 {
    (id as f64 * 0.618_033_988_749_895).rem_euclid(1.0)
}

#[unsafe(no_mangle)]
extern "C" fn oc_tab_step(current: i64, count: i64, delta: i64) -> i64 {
    step(current, count, delta)
}

#[unsafe(no_mangle)]
extern "C" fn oc_tab_for_digit(digit: i64, count: i64) -> i64 {
    for_digit(digit, count)
}

#[unsafe(no_mangle)]
extern "C" fn oc_tab_hue(id: i64) -> f64 {
    hue(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn step_clamps_at_both_ends() {
        assert_eq!(step(0, 3, -1), 0);
        assert_eq!(step(2, 3, 1), 2);
        assert_eq!(step(1, 3, 1), 2);
        assert_eq!(step(1, 3, -1), 0);
        assert_eq!(step(0, 3, i64::MAX), 2);
        assert_eq!(step(2, 3, i64::MIN), 0);
    }

    #[test]
    fn step_with_empty_or_single_tab_is_zero() {
        assert_eq!(step(0, 1, 1), 0);
        assert_eq!(step(5, 0, 1), 0);
    }

    #[test]
    fn digit_maps_to_index_or_minus_one() {
        assert_eq!(for_digit(1, 3), 0);
        assert_eq!(for_digit(3, 3), 2);
        assert_eq!(for_digit(4, 3), -1);
        assert_eq!(for_digit(0, 3), -1);
        assert_eq!(for_digit(10, 20), -1);
    }

    #[test]
    fn hue_is_stable_in_unit_range_and_spreads_neighbours() {
        assert_eq!(hue(7), hue(7));
        for id in -5..200 {
            let h = hue(id);
            assert!((0.0..1.0).contains(&h), "hue({id}) = {h}");
        }
        for id in 1..100 {
            let d = (hue(id) - hue(id + 1)).abs();
            assert!(d.min(1.0 - d) >= 0.3, "ids {id}/{} too close: {d}", id + 1);
        }
    }
}
