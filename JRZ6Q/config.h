#define CHORDAL_HOLD
#define USB_SUSPEND_WAKEUP_DELAY 0
#define SERIAL_NUMBER "JRZ6Q/0WNAgG"
#define LAYER_STATE_8BIT

#define AUTOMOUSE_LAYER 5
#define AUTOMOUSE_TIMEOUT 250
#define AUTOMOUSE_THRESHOLD 10
#define TRACKPAD_TAP_TERM_MS 0  // disable firmware tap-to-click (mouse-fallback mode); 0 = no tap qualifies

// Mode-0 (no-app) cursor speed — only active when Navigator.app is not driving the pad.
// #undef silences the benign -Wmacro-redefined (module config.h sets a default first).
#undef  TRACKPAD_MOUSE_SENSITIVITY
#define TRACKPAD_MOUSE_SENSITIVITY 0.51f   // cursor speed (−15% from 0.6)
#undef  TRACKPAD_MOUSE_ACCELERATION
#define TRACKPAD_MOUSE_ACCELERATION 1.3f

#define TRACKPAD_SCROLL_SENSITIVITY 0.02f  // two-finger scroll speed (−50% from 0.04; patch default 0.10)
#define TRACKPAD_SCROLL_DECAY 0.96f        // momentum coast length (patch default 0.95; ~+30% coast)

#define RGB_MATRIX_STARTUP_SPD 60

