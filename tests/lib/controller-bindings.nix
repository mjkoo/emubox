# Hand-typed expected values for the controller bindings modules/controllers
# declares, shared by every test that checks them so a binding change is one
# edit here rather than one per test. Typed independently of that module and
# never read back from it, so a wrong value there cannot agree with itself
# here.
let
  sdl = i: "SDL-${toString i}";
in
{
  # PCSX2's own Controller Port > Automatic Mapping output for SDL pad `i`.
  pcsx2Pad = i: {
    Up = "${sdl i}/DPadUp";
    Right = "${sdl i}/DPadRight";
    Down = "${sdl i}/DPadDown";
    Left = "${sdl i}/DPadLeft";
    Triangle = "${sdl i}/FaceNorth";
    Circle = "${sdl i}/FaceEast";
    Cross = "${sdl i}/FaceSouth";
    Square = "${sdl i}/FaceWest";
    Select = "${sdl i}/Back";
    Start = "${sdl i}/Start";
    L1 = "${sdl i}/LeftShoulder";
    L2 = "${sdl i}/+LeftTrigger";
    R1 = "${sdl i}/RightShoulder";
    R2 = "${sdl i}/+RightTrigger";
    L3 = "${sdl i}/LeftStick";
    R3 = "${sdl i}/RightStick";
    Analog = "${sdl i}/Guide";
    LUp = "${sdl i}/-LeftY";
    LRight = "${sdl i}/+LeftX";
    LDown = "${sdl i}/+LeftY";
    LLeft = "${sdl i}/-LeftX";
    RUp = "${sdl i}/-RightY";
    RRight = "${sdl i}/+RightX";
    RDown = "${sdl i}/+RightY";
    RLeft = "${sdl i}/-RightX";
    LargeMotor = "${sdl i}/LargeMotor";
    SmallMotor = "${sdl i}/SmallMotor";
  };

  # DuckStation's own Automatic Mapping output for SDL pad `i`: PCSX2's
  # shape with DuckStation's own face-button names.
  duckstationPad = i: {
    Up = "${sdl i}/DPadUp";
    Right = "${sdl i}/DPadRight";
    Down = "${sdl i}/DPadDown";
    Left = "${sdl i}/DPadLeft";
    Triangle = "${sdl i}/Y";
    Circle = "${sdl i}/B";
    Cross = "${sdl i}/A";
    Square = "${sdl i}/X";
    Select = "${sdl i}/Back";
    Start = "${sdl i}/Start";
    L1 = "${sdl i}/LeftShoulder";
    L2 = "${sdl i}/+LeftTrigger";
    R1 = "${sdl i}/RightShoulder";
    R2 = "${sdl i}/+RightTrigger";
    L3 = "${sdl i}/LeftStick";
    R3 = "${sdl i}/RightStick";
    Analog = "${sdl i}/Guide";
    LUp = "${sdl i}/-LeftY";
    LRight = "${sdl i}/+LeftX";
    LDown = "${sdl i}/+LeftY";
    LLeft = "${sdl i}/-LeftX";
    RUp = "${sdl i}/-RightY";
    RRight = "${sdl i}/+RightX";
    RDown = "${sdl i}/+RightY";
    RLeft = "${sdl i}/-RightX";
    LargeMotor = "${sdl i}/LargeMotor";
    SmallMotor = "${sdl i}/SmallMotor";
  };

  # PPSSPP's complete PSP gameplay set in controls.ini, without the Pause
  # route back, which is enforced rather than seeded.
  ppssppControls = {
    Up = "10-19";
    Down = "10-20";
    Left = "10-21";
    Right = "10-22";
    Cross = "10-189";
    Circle = "10-190";
    Square = "10-191";
    Triangle = "10-188";
    Start = "10-197";
    Select = "10-196";
    L = "10-193";
    R = "10-192";
    "An.Up" = "10-4003";
    "An.Down" = "10-4002";
    "An.Left" = "10-4001";
    "An.Right" = "10-4000";
  };

  # Dolphin's GameCube profile for SDL pad `i`, whose SDL device name is
  # `name`.
  gcPad = i: name: {
    Device = "SDL/${toString i}/${name}";
    "Buttons/A" = "`Button S`";
    "Buttons/B" = "`Button E`";
    "Buttons/X" = "`Button W`";
    "Buttons/Y" = "`Button N`";
    "Buttons/Z" = "`Shoulder R`";
    "Buttons/Start" = "Start";
    "Main Stick/Up" = "`Left Y+`";
    "Main Stick/Down" = "`Left Y-`";
    "Main Stick/Left" = "`Left X-`";
    "Main Stick/Right" = "`Left X+`";
    "Main Stick/Calibration" = "";
    "C-Stick/Up" = "`Right Y+`";
    "C-Stick/Down" = "`Right Y-`";
    "C-Stick/Left" = "`Right X-`";
    "C-Stick/Right" = "`Right X+`";
    "C-Stick/Calibration" = "";
    "Triggers/L" = "`Trigger L`";
    "Triggers/R" = "`Trigger R`";
    "Triggers/L-Analog" = "`Trigger L`";
    "Triggers/R-Analog" = "`Trigger R`";
    "D-Pad/Up" = "`Pad N`";
    "D-Pad/Down" = "`Pad S`";
    "D-Pad/Left" = "`Pad W`";
    "D-Pad/Right" = "`Pad E`";
  };

  # Dolphin's Wii profile for SDL pad `i`, with `Source` connecting every
  # Wii Remote slot after the first.
  wiimote =
    i: name:
    {
      Device = "SDL/${toString i}/${name}";
      "Buttons/A" = "`Button S`";
      "Buttons/B" = "`Trigger R`";
      "Buttons/1" = "`Button W`";
      "Buttons/2" = "`Button N`";
      "Buttons/-" = "Back";
      "Buttons/+" = "Start";
      "Buttons/Home" = "Guide";
      "D-Pad/Up" = "`Pad N`";
      "D-Pad/Down" = "`Pad S`";
      "D-Pad/Left" = "`Pad W`";
      "D-Pad/Right" = "`Pad E`";
      "IR/Up" = "`Right Y+`";
      "IR/Down" = "`Right Y-`";
      "IR/Left" = "`Right X-`";
      "IR/Right" = "`Right X+`";
      "Shake/X" = "`Button E`";
      "Shake/Y" = "`Button E`";
      "Shake/Z" = "`Button E`";
      Extension = "Nunchuk";
      "Nunchuk/Buttons/C" = "`Shoulder L`";
      "Nunchuk/Buttons/Z" = "`Trigger L`";
      "Nunchuk/Stick/Up" = "`Left Y+`";
      "Nunchuk/Stick/Down" = "`Left Y-`";
      "Nunchuk/Stick/Left" = "`Left X-`";
      "Nunchuk/Stick/Right" = "`Left X+`";
      "Nunchuk/Stick/Calibration" = "";
      "Nunchuk/Shake/X" = "`Thumb L`";
      "Nunchuk/Shake/Y" = "`Thumb L`";
      "Nunchuk/Shake/Z" = "`Thumb L`";
    }
    // (if i != 0 then { Source = "1"; } else { });

  # Azahar's gameplay bindings for the pad whose SDL joystick GUID is
  # `guid`, each value in the double-quoted, key-sorted spelling Azahar's
  # own writer produces.
  azahar =
    guid:
    let
      button = n: ''"button:${toString n},engine:sdl,guid:${guid},port:0"'';
      hat = direction: ''"direction:${direction},engine:sdl,guid:${guid},hat:0,port:0"'';
      axisButton =
        axis: ''"axis:${toString axis},direction:+,engine:sdl,guid:${guid},port:0,threshold:0.5"'';
      analog =
        x: y:
        ''"axis_x:${toString x},axis_y:${toString y},deadzone:0.100000,engine:sdl,guid:${guid},port:0"'';
    in
    {
      button_a = button 1;
      button_b = button 0;
      button_x = button 3;
      button_y = button 2;
      button_up = hat "up";
      button_down = hat "down";
      button_left = hat "left";
      button_right = hat "right";
      button_l = button 4;
      button_r = button 5;
      button_start = button 7;
      button_select = button 6;
      button_zl = axisButton 2;
      button_zr = axisButton 5;
      button_home = button 8;
      circle_pad = analog 0 1;
      c_stick = analog 3 4;
    };
}
