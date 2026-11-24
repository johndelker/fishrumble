addon.name = 'Fish Rumble';
addon.author = 'SlowCircuit';
addon.version = '1.0.0';
addon.desc = 'Makes controller vibration during fishing happen on the side that you need to move the rod. Very customizable.';

require('common');

local ffi = require('ffi');
local settings = require('settings');
local imgui = require('imgui');

ffi.cdef[[
    typedef struct {
        uint16_t left;
        uint16_t right;
    } fishrumble_vibration;

    uint64_t __stdcall GetTickCount64(void);
    uint32_t __stdcall XInputSetState(uint32_t index, const void* vibration);
]];

local vibration = ffi.new('fishrumble_vibration[1]');
local config = settings.load(T{ minStrength = 0, strength = 100, pattern = 2, leftFrequency = 0, rightFrequency = 0 });
local patterns = {
    { name = 'Constant', period = 400, level = function () return 1; end },
    { name = 'Pulse (Square)', period = 250, level = function (elapsed) return elapsed % 250 < 125 and 1 or 0; end },
    { name = 'Double Tap', period = 500, level = function (elapsed)
        local phase = elapsed % 500;
        return (phase < 85 or (phase >= 155 and phase < 240)) and 1 or 0;
    end },
    { name = 'Triangle', period = 400, level = function (elapsed)
        local phase = (elapsed % 400) / 200;
        return 1 - math.abs(1 - phase);
    end },
    { name = 'Sine', period = 1000, level = function (elapsed)
        return (1 - math.cos(2 * math.pi * elapsed / 1000)) / 2;
    end },
    { name = 'Sawtooth', period = 1000, level = function (elapsed)
        return (elapsed % 1000) / 1000;
    end },
};
local frequencies = {
    { hz = 0.5, label = 'Very Slow (0.5 Hz)' },
    { hz = 1, label = 'Slow (1.0 Hz)' },
    { hz = 2, label = 'Normal (2.0 Hz)' },
    { hz = 3, label = 'Fast (3.0 Hz)' },
    { hz = 4, label = 'Very Fast (4.0 Hz)' },
};
local cueDirection;
local cueStarted;
local configOpen = { false };
local testSide;
local testStarted;
local testDuration = 6000;

local function nearestFrequency(hz)
    local nearest = frequencies[1];
    for _, option in ipairs(frequencies) do
        if (math.abs(option.hz - hz) < math.abs(nearest.hz - hz)) then
            nearest = option;
        end
    end
    return nearest;
end

local function migrateFrequency()
    local fallback = config.frequency and config.frequency * 1000 / patterns[config.pattern].period or 2;
    local left = nearestFrequency(config.leftFrequency == 0 and fallback or config.leftFrequency).hz;
    local right = nearestFrequency(config.rightFrequency == 0 and fallback or config.rightFrequency).hz;
    if (left ~= config.leftFrequency or right ~= config.rightFrequency or config.frequency ~= nil) then
        config.leftFrequency = left;
        config.rightFrequency = right;
        config.frequency = nil;
        settings.save();
    end
end
migrateFrequency();
settings.register('settings', 'fishrumble_settings', function (updated)
    config = updated;
    migrateFrequency();
    cueDirection = nil;
end);
local nextProbe = 0;
local controller;
local applied;
local appliedSpeed;
local setState;
local phaseAddress;
local gameAddress;
local nativeVibrationAddress;
local nativeVibration;

local function stop()
    if (controller ~= nil and applied ~= nil) then
        vibration[0].left = 0;
        vibration[0].right = 0;
        if (setState(controller, vibration) ~= 0) then
            controller = nil;
        end
        applied = nil;
    end
end

local function restoreNativeVibration()
    if (nativeVibration ~= nil) then
        local memory = ashita.memory;
        if (memory.read_uint32(nativeVibrationAddress) == 0) then
            memory.write_uint32(nativeVibrationAddress, nativeVibration);
        end
        nativeVibration = nil;
    end
end

local function muteNativeVibration()
    local memory = ashita.memory;
    local current = memory.read_uint32(nativeVibrationAddress);
    if (current ~= 0) then
        -- The client's wrapper skips vibration when this export slot is zero.
        -- Controller input uses a separate slot.
        memory.write_uint32(nativeVibrationAddress, 0);
        nativeVibration = current;
    end
end

local function rumble(direction, strength, now)
    if (applied == direction and appliedSpeed == strength) then
        return;
    end

    vibration[0].left = direction == 'left' and strength or 0;
    vibration[0].right = direction == 'right' and strength or 0;

    if (controller ~= nil) then
        if (setState(controller, vibration) == 0) then
            applied, appliedSpeed = direction, strength;
            return;
        end
        controller = nil;
        applied = nil;
    end

    if (now < nextProbe) then
        return;
    end
    nextProbe = now + 1000;

    for index = 0, 3 do
        if (setState(index, vibration) == 0) then
            controller = index;
            applied, appliedSpeed = direction, strength;
            nextProbe = 0;
            return;
        end
    end
end

local function locate(pattern, operand)
    local memory = ashita.memory;
    local match = memory.find('FFXiMain.dll', 0, pattern, 0, 0);
    if (match == nil or match == 0 or (memory.find('FFXiMain.dll', 0, pattern, 0, 1) or 0) ~= 0) then
        return nil;
    end
    local address = memory.read_uint32(match + operand);
    return address ~= 0 and address or nil;
end

ashita.events.register('load', 'fishrumble_load', function ()
    -- The minigame update dispatches phase 2 when its arrow input window is open.
    phaseAddress = locate('8B0D????????8D410183F8030F87????????FF2485', 2);
    -- The same update reads the current minigame pointer and its direction field
    -- to select the rod animation. The pointer is cleared when the minigame ends.
    gameAddress = locate('A1????????8B8EA000000053518B40308B118B0485????????50FF9298020000', 1);
    if (phaseAddress == nil or gameAddress == nil) then
        print('[FishRumble] This FFXI client build has an unrecognized fishing routine.');
        return;
    end

    -- Resolve the XInputSetState export slot from FFXI's own vibration wrapper.
    nativeVibrationAddress = locate('A1????????68????????50FFD68B0D????????68????????51A3????????FFD6A3????????B0015EC3', 26);
    if (nativeVibrationAddress == nil) then
        print('[FishRumble] This FFXI build has an unrecognized XInput vibration routine.');
        return;
    end

    for _, name in ipairs({ 'xinput1_4', 'xinput1_3', 'xinput9_1_0' }) do
        local ok, library = pcall(ffi.load, name);
        if (ok) then
            local exportOk = pcall(function () return library.XInputSetState; end);
            if (exportOk) then
                setState = function (index, motors)
                    return library.XInputSetState(index, motors);
                end;
                return;
            end
        end
    end

    print('[FishRumble] Windows XInput is unavailable.');
end);

local function selectPattern(index)
    config.pattern = index;
    cueDirection = nil;
    settings.save();
end

local function patternPercent(pattern, elapsed, frequency)
    return config.minStrength + (config.strength - config.minStrength) * pattern.level(elapsed * frequency * pattern.period / 1000);
end

local controlColumn = 165;

local function settingLabel(label)
    imgui.AlignTextToFramePadding();
    imgui.Text(label);
    imgui.SameLine(controlColumn);
    imgui.SetNextItemWidth(-1);
end

local function drawFrequency(label, key)
    settingLabel(label);
    if (imgui.BeginCombo('##' .. key, nearestFrequency(config[key]).label, ImGuiComboFlags_None)) then
        for _, option in ipairs(frequencies) do
            if (imgui.Selectable(option.label, config[key] == option.hz)) then
                config[key] = option.hz;
                settings.save();
            end
        end
        imgui.EndCombo();
    end
end

local function drawConfig(now)
    if (not configOpen[1]) then
        return;
    end

    imgui.SetNextWindowSize({ 458, 266 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('Fish Rumble', configOpen)) then
        local minimum = { config.minStrength };
        local maximum = { config.strength };
        settingLabel('Min Strength');
        if (imgui.SliderFloat('##minStrength', minimum, 0, config.strength, '%.1f%%')) then
            config.minStrength = minimum[1];
            settings.save();
        end
        settingLabel('Max Strength');
        if (imgui.SliderFloat('##maxStrength', maximum, config.minStrength, 100, '%.1f%%')) then
            config.strength = maximum[1];
            settings.save();
        end

        settingLabel('Pattern');
        if (imgui.BeginCombo('##pattern', patterns[config.pattern].name, ImGuiComboFlags_None)) then
            for index, pattern in ipairs(patterns) do
                if (imgui.Selectable(pattern.name, config.pattern == index)) then
                    selectPattern(index);
                end
            end
            imgui.EndCombo();
        end

        local pattern = patterns[config.pattern];
        local samples = {};
        for sample = 1, 201 do
            samples[sample] = pattern.level((sample - 1) * pattern.period / 100);
        end
        imgui.SetCursorPosX(controlColumn);
        imgui.PlotLines('##waveform', samples, #samples, 0, '', -0.1, 1.1,
            { math.max(1, (imgui.GetContentRegionAvail())), 18 });

        drawFrequency('Left Frequency', 'leftFrequency');
        drawFrequency('Right Frequency', 'rightFrequency');

        for _, test in ipairs({ { 'left', 'Left Test' }, { 'right', 'Right Test' } }) do
            local side, label = test[1], test[2];
            local running = testSide == side and now - testStarted < testDuration;
            local button = (running and 'Stop Test' or label) .. '###fishrumble_test_' .. side;
            if (imgui.Button(button, { 110, 0 })) then
                if (running) then
                    testSide, testStarted = nil, nil;
                    stop();
                else
                    testSide, testStarted = side, now;
                end
            end
            if (testSide == side and now - testStarted < testDuration) then
                local secondsLeft = math.ceil((testDuration - (now - testStarted)) / 1000);
                imgui.SameLine();
                imgui.Text(('Testing... %d'):format(secondsLeft));
            end
        end
    end
    imgui.End();
end
local function playPattern(side, elapsed, now)
    local frequency = side == 'left' and config.leftFrequency or config.rightFrequency;
    local strength = math.floor(patternPercent(patterns[config.pattern], elapsed, frequency) * 65535 / 100 + 0.5);
    if (strength > 0) then
        rumble(side, strength, now);
    else
        stop();
    end
end

ashita.events.register('command', 'fishrumble_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/fishrumble') then
        return;
    end

    e.blocked = true;
    if (#args == 1) then
        configOpen[1] = true;
    end
end);
ashita.events.register('d3d_present', 'fishrumble_present', function ()
    local now = tonumber(ffi.C.GetTickCount64());
    drawConfig(now);
    if (setState == nil) then
        return;
    end

    local memory = ashita.memory;
    local game = memory.read_uint32(gameAddress);
    if (testSide ~= nil) then
        if (configOpen[1] and now - testStarted < testDuration) then
            cueDirection = nil;
            muteNativeVibration();
            playPattern(testSide, now - testStarted, now);
            return;
        end
        testSide = nil;
        stop();
    end
    if (game == 0) then
        cueDirection = nil;
        stop();
        restoreNativeVibration();
        return;
    end

    muteNativeVibration();
    if (memory.read_int32(phaseAddress) == 2) then
        if (memory.read_int32(game + 0x04) > 0) then
            -- Both white and gold arrows use this field. Zero is the positive
            -- horizontal input (right). One is the negative input (left).
            local direction = memory.read_int32(game + 0x30);
            if (direction == 0 or direction == 1) then
                local side = direction == 0 and 'right' or 'left';
                if (cueDirection ~= side) then
                    cueDirection = side;
                    cueStarted = now;
                end
                playPattern(side, now - cueStarted, now);
                return;
            end
        end
    end

    cueDirection = nil;
    stop();
end);

ashita.events.register('unload', 'fishrumble_unload', function ()
    stop();
    restoreNativeVibration();
end);

