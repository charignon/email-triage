-- email-triage.lua - Tinder-style email triage interface
-- Full-screen panel for rapid inbox processing
--
-- Keys:
--   <- (left)  Archive
--   -> (right) Create task + Archive
--   v (down)   Delete
--   ^ (up)     Suppress (unsubscribe task) + Archive
--   Escape     Close panel
--   j/k        Scroll email body
--   n/p        Next/Previous email (if you want to skip)

require("hs.canvas")
require("hs.task")
require("hs.eventtap")

local Panel = require("panel-base")

local M = {}

-- Forward declarations for functions used in callbacks before definition
local render
local schedulePrefetch

-----------------------------------------------------------
-- CONFIGURATION
-----------------------------------------------------------

local HELPER_PATH = os.getenv("HOME") .. "/bin/email-triage"
local MAX_EMAILS = 500  -- Large batch for offline use
local INITIAL_FETCH = 50  -- First fetch is smaller for quick startup
local REFETCH_THRESHOLD = 15  -- Fetch more when below this (stay way ahead)
local DEBOUNCE_SECONDS = 0.5  -- Minimum time between fetches
local MUSIC_MILESTONE = 10  -- Play faster music every N emails

-- Medal thresholds
local BRONZE_PER_SILVER = 5   -- 5 bronze = 1 silver (50 emails)
local SILVER_PER_GOLD = 2     -- 2 silver = 1 gold (100 emails)

-- Green gradient colors for the progress bar
local GREEN_LIGHT = {red = 0.4, green = 0.9, blue = 0.5, alpha = 0.9}
local GREEN_DARK = {red = 0.2, green = 0.7, blue = 0.3, alpha = 0.95}

-- Color palette for email display (rotating)
local EMAIL_COLORS = {
    {red = 0.4, green = 0.8, blue = 1.0, alpha = 1},    -- Cyan
    {red = 1.0, green = 0.6, blue = 0.4, alpha = 1},    -- Coral
    {red = 0.6, green = 1.0, blue = 0.6, alpha = 1},    -- Mint
    {red = 1.0, green = 0.8, blue = 0.4, alpha = 1},    -- Gold
    {red = 0.8, green = 0.6, blue = 1.0, alpha = 1},    -- Lavender
    {red = 1.0, green = 0.5, blue = 0.7, alpha = 1},    -- Pink
    {red = 0.5, green = 0.9, blue = 0.8, alpha = 1},    -- Teal
    {red = 1.0, green = 0.7, blue = 0.5, alpha = 1},    -- Peach
}

-----------------------------------------------------------
-- STATE
-----------------------------------------------------------

local state = {
    visible = false,
    canvas = nil,
    webview = nil,         -- Webview for HTML email body
    emails = {},           -- List of email objects
    currentIndex = 1,      -- 1-based index
    total = 0,             -- Total emails in inbox
    isLoading = false,
    isFetching = false,    -- Background fetch in progress
    error = nil,
    scrollOffset = 0,      -- For scrolling long emails
    actionTask = nil,      -- Current action task
    fetchTask = nil,       -- Background fetch task
    keyTap = nil,          -- Keyboard event tap
    triaged = 0,           -- Emails triaged this session
    undoStack = {},        -- Stack of {email, action, index} for undo
    -- Label picker state
    labelPickerVisible = false,
    labelPickerCanvas = nil,
    allLabels = {},        -- All available labels
    emailLabelIds = {},    -- Current email's label IDs
}

-- Pastel colors for label picker
local PASTEL_COLORS = {
    pink = {red = 1.0, green = 0.8, blue = 0.85, alpha = 1},
    peach = {red = 1.0, green = 0.85, blue = 0.75, alpha = 1},
    yellow = {red = 1.0, green = 0.95, blue = 0.7, alpha = 1},
    mint = {red = 0.75, green = 0.95, blue = 0.8, alpha = 1},
    sky = {red = 0.75, green = 0.88, blue = 1.0, alpha = 1},
    lavender = {red = 0.88, green = 0.8, blue = 1.0, alpha = 1},
    coral = {red = 1.0, green = 0.75, blue = 0.75, alpha = 1},
    sage = {red = 0.8, green = 0.9, blue = 0.8, alpha = 1},
}
local PASTEL_LIST = {"pink", "peach", "yellow", "mint", "sky", "lavender", "coral", "sage"}

-- Pre-fetch cache (persists between show/hide)
local cache = {
    emails = {},
    total = 0,
    lastFetch = 0,
    prefetchTask = nil,
    fetchTimer = nil,  -- Debounce timer
    isOnline = true,   -- Connectivity status
    pendingCount = 0,  -- Queued offline actions
    syncTimer = nil,   -- Periodic sync timer
}

-----------------------------------------------------------
-- OFFLINE SUPPORT
-----------------------------------------------------------

-- Load cached emails from disk
local function loadCacheFromDisk()
    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            local ok, data = pcall(hs.json.decode, stdOut)
            if ok and data and data.success and data.emails then
                cache.emails = data.emails
                cache.total = data.total or #data.emails
            end
        end
    end, {"cache-load"})
    task:start()
end

-- Save cache to disk
local function saveCacheToDisk()
    if #cache.emails == 0 then return end

    local data = hs.json.encode({
        emails = cache.emails,
        total = cache.total
    })

    local task = hs.task.new(HELPER_PATH, function() end,
        {"cache-save", data})
    task:start()
end

-- Check online status
local function checkOnline(callback)
    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            local ok, data = pcall(hs.json.decode, stdOut)
            if ok and data then
                cache.isOnline = data.online == true
                if callback then callback(cache.isOnline) end
            end
        else
            cache.isOnline = false
            if callback then callback(false) end
        end
    end, {"check-online"})
    task:start()
end

-- Queue an action for offline sync
local function queueOfflineAction(email, action)
    local args = {
        "queue", action, email.id,
        "--thread-id", email.threadId or "",
        "--subject", email.subject or "",
        "--from-addr", email["from"] or "",
        "--snippet", email.snippet or ""
    }

    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            cache.pendingCount = cache.pendingCount + 1
        end
    end, args)
    task:start()
end

-- Sync pending actions
local function syncPendingActions(callback)
    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            local ok, data = pcall(hs.json.decode, stdOut)
            if ok and data then
                cache.pendingCount = data.pending or 0
                cache.isOnline = data.error ~= "offline"
                if callback then callback(data) end
            end
        end
    end, {"sync"})
    task:start()
end

-- Start periodic sync attempts
local function startSyncTimer()
    if cache.syncTimer then return end
    cache.syncTimer = hs.timer.doEvery(30, function()
        if cache.pendingCount > 0 then
            syncPendingActions(function(data)
                if state.visible and data.synced and data.synced > 0 then
                    render()  -- Update UI to show sync status
                end
            end)
        else
            -- Just check online status
            checkOnline()
        end
    end)
end

local function stopSyncTimer()
    if cache.syncTimer then
        cache.syncTimer:stop()
        cache.syncTimer = nil
    end
end

-----------------------------------------------------------
-- UTILITIES
-----------------------------------------------------------

local function getCurrentEmailColor()
    -- Cycle through colors based on triaged count
    local colorIndex = (state.triaged % #EMAIL_COLORS) + 1
    return EMAIL_COLORS[colorIndex]
end

-- Sort emails by internalDate (newest first)
local function sortEmailsByDate(emails)
    table.sort(emails, function(a, b)
        local dateA = a.internalDate or 0
        local dateB = b.internalDate or 0
        return dateA > dateB  -- Descending (newest first)
    end)
end

-----------------------------------------------------------
-- LABEL PICKER
-----------------------------------------------------------

-- Key hints for labels (a-z excluding used keys like e, t, x, s, l)
local LABEL_HINTS = "abcdfghijkmnopqruvwyz1234567890"

local function hideLabelPicker()
    if state.labelPickerCanvas then
        state.labelPickerCanvas:delete()
        state.labelPickerCanvas = nil
    end
    state.labelPickerVisible = false
end

local function renderLabelPicker()
    if not state.labelPickerVisible then return end

    hideLabelPicker()  -- Clear existing

    local screen = hs.screen.mainScreen():fullFrame()
    local numLabels = #state.allLabels
    local numCols = numLabels > 15 and 3 or (numLabels > 8 and 2 or 1)
    local colWidth = 220
    local rowHeight = 38
    local padding = 20
    local pickerWidth = numCols * colWidth + padding * 2
    local rowsPerCol = math.ceil(numLabels / numCols)
    local pickerHeight = rowsPerCol * rowHeight + padding * 2 + 60

    local x = (screen.w - pickerWidth) / 2
    local y = (screen.h - pickerHeight) / 2

    state.labelPickerCanvas = hs.canvas.new({x = x, y = y, w = pickerWidth, h = pickerHeight})
    state.labelPickerCanvas:level(hs.canvas.windowLevels.overlay + 2)

    local idx = 1

    -- Background with rounded corners
    state.labelPickerCanvas[idx] = {
        type = "rectangle",
        frame = {x = 0, y = 0, w = pickerWidth, h = pickerHeight},
        fillColor = {red = 0.12, green = 0.12, blue = 0.14, alpha = 0.98},
        roundedRectRadii = {xRadius = 16, yRadius = 16},
    }
    idx = idx + 1

    -- Title
    state.labelPickerCanvas[idx] = {
        type = "text",
        text = hs.styledtext.new("Labels", {
            font = {name = "Helvetica Neue Bold", size = 18},
            color = {red = 1, green = 1, blue = 1, alpha = 1},
            paragraphStyle = {alignment = "center"},
        }),
        frame = {x = 0, y = padding, w = pickerWidth, h = 28},
    }
    idx = idx + 1

    -- Subtitle
    state.labelPickerCanvas[idx] = {
        type = "text",
        text = hs.styledtext.new("Press letter to toggle • Esc to close", {
            font = {name = "Helvetica Neue", size = 11},
            color = {red = 0.5, green = 0.5, blue = 0.5, alpha = 1},
            paragraphStyle = {alignment = "center"},
        }),
        frame = {x = 0, y = padding + 24, w = pickerWidth, h = 18},
    }
    idx = idx + 1

    -- Labels in columns
    local startY = padding + 50
    for i, label in ipairs(state.allLabels) do
        if i > #LABEL_HINTS then break end

        local hint = LABEL_HINTS:sub(i, i)
        local col = math.floor((i - 1) / rowsPerCol)
        local row = (i - 1) % rowsPerCol
        local colX = padding + col * colWidth
        local rowY = startY + row * rowHeight

        local pastelName = PASTEL_LIST[(i - 1) % #PASTEL_LIST + 1]
        local pastelColor = PASTEL_COLORS[pastelName]
        local isActive = false

        -- Check if label is active on current email
        for _, labelId in ipairs(state.emailLabelIds) do
            if labelId == label.id then
                isActive = true
                break
            end
        end

        -- Row background (highlighted if active)
        if isActive then
            state.labelPickerCanvas[idx] = {
                type = "rectangle",
                frame = {x = colX, y = rowY, w = colWidth - 10, h = rowHeight - 4},
                fillColor = {red = pastelColor.red, green = pastelColor.green, blue = pastelColor.blue, alpha = 0.2},
                roundedRectRadii = {xRadius = 6, yRadius = 6},
            }
            idx = idx + 1
        end

        -- Hint badge (pastel colored circle)
        state.labelPickerCanvas[idx] = {
            type = "circle",
            center = {x = colX + 14, y = rowY + rowHeight / 2 - 2},
            radius = 12,
            fillColor = pastelColor,
        }
        idx = idx + 1

        -- Hint letter
        state.labelPickerCanvas[idx] = {
            type = "text",
            text = hs.styledtext.new(hint:upper(), {
                font = {name = "Menlo-Bold", size = 11},
                color = {red = 0.15, green = 0.15, blue = 0.15, alpha = 1},
                paragraphStyle = {alignment = "center"},
            }),
            frame = {x = colX + 2, y = rowY + rowHeight / 2 - 8, w = 24, h = 16},
        }
        idx = idx + 1

        -- Label name (truncated if needed)
        local displayName = #label.name > 18 and label.name:sub(1, 16) .. "…" or label.name
        state.labelPickerCanvas[idx] = {
            type = "text",
            text = hs.styledtext.new(displayName, {
                font = {name = "Helvetica Neue", size = 13},
                color = isActive and pastelColor or {red = 0.85, green = 0.85, blue = 0.85, alpha = 1},
            }),
            frame = {x = colX + 32, y = rowY + rowHeight / 2 - 9, w = colWidth - 60, h = 18},
        }
        idx = idx + 1

        -- Checkmark if active
        if isActive then
            state.labelPickerCanvas[idx] = {
                type = "text",
                text = hs.styledtext.new("✓", {
                    font = {name = "Helvetica Neue Bold", size = 14},
                    color = pastelColor,
                }),
                frame = {x = colX + colWidth - 30, y = rowY + rowHeight / 2 - 9, w = 20, h = 18},
            }
            idx = idx + 1
        end
    end

    state.labelPickerCanvas:show()
end

local function toggleLabel(labelIndex)
    local label = state.allLabels[labelIndex]
    if not label then return end

    local email = state.emails[state.currentIndex]
    if not email then return end

    -- Check if label is currently active
    local isActive = false
    local activeIdx = nil
    for i, labelId in ipairs(state.emailLabelIds) do
        if labelId == label.id then
            isActive = true
            activeIdx = i
            break
        end
    end

    if isActive then
        -- Just remove the label
        table.remove(state.emailLabelIds, activeIdx)
        renderLabelPicker()

        local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
            -- Silently handle
        end, {"remove-label", email.id, label.id})
        task:start()
    else
        -- Add label AND archive (skip inbox + mark as read)
        hideLabelPicker()

        -- Update counts
        state.triaged = state.triaged + 1
        if state.total > 0 then
            state.total = state.total - 1
        end
        if cache.total > 0 then
            cache.total = cache.total - 1
        end

        -- Play music milestone
        if state.triaged > 0 and state.triaged % MUSIC_MILESTONE == 0 then
            playMusicForMilestone(state.triaged)
        end

        -- Remove from lists
        local emailId = email.id
        table.remove(state.emails, state.currentIndex)
        for i, e in ipairs(cache.emails) do
            if e.id == emailId then
                table.remove(cache.emails, i)
                break
            end
        end

        -- Adjust index
        if state.currentIndex > #state.emails then
            state.currentIndex = math.max(1, #state.emails)
        end

        -- Show next email
        render()
        schedulePrefetch()

        -- Add label in background
        local task1 = hs.task.new(HELPER_PATH, function() end, {"add-label", emailId, label.id})
        task1:start()

        -- Archive in background
        local task2 = hs.task.new(HELPER_PATH, function() end, {"archive", emailId})
        task2:start()
    end
end

local function fetchLabelsAndShow()
    local email = state.emails[state.currentIndex]
    if not email then return end

    state.labelPickerVisible = true
    state.emailLabelIds = email.labelIds or {}

    -- If we already have labels cached, show immediately
    if #state.allLabels > 0 then
        renderLabelPicker()
    end

    -- Fetch labels from API
    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            local ok, data = pcall(hs.json.decode, stdOut)
            if ok and data and data.success and data.labels then
                state.allLabels = data.labels
                if state.labelPickerVisible then
                    renderLabelPicker()
                end
            end
        end
    end, {"labels"})
    task:start()
end

-- Spotify control via AppleScript (no API needed)
-- Every 10 emails: skip to fresh track (only if Spotify is already running)
local function playMusicForMilestone(triagedCount)
    local script = [[
        -- Only interact with Spotify if it's already running
        if application "Spotify" is not running then
            return "not_running"
        end if

        tell application "Spotify"
            -- Only skip track if already playing
            if player state is playing then
                next track
                delay 0.3

                -- Get current track info
                set trackName to name of current track
                set artistName to artist of current track
                return trackName & " | " & artistName
            else
                return "not_playing"
            end if
        end tell
    ]]

    hs.osascript.applescript(script, function(success, result, rawOutput)
        if success and result and result ~= "not_running" and result ~= "not_playing" then
            local name, artist = result:match("(.+) | (.+)")
            if name then
                local tierIndex = math.floor(triagedCount / MUSIC_MILESTONE)
                local tierNames = {"🔥", "🔥🔥", "🔥🔥🔥", "💥💥💥", "🚀🚀🚀", "⚡⚡⚡"}
                local tierEmoji = tierNames[math.min(tierIndex, #tierNames)]

                hs.notify.new({
                    title = tierEmoji .. " Level " .. tierIndex .. "! (" .. triagedCount .. " emails)",
                    informativeText = string.format("%s - %s", name, artist),
                    withdrawAfter = 3,
                }):send()
            end
        end
    end)
end

-- Parse email date string and return days ago
local function parseDateAndDaysAgo(dateStr)
    if not dateStr or dateStr == "" then
        return nil, nil
    end

    -- Month name to number mapping
    local months = {
        Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
        Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
    }

    -- Parse "Mon, 8 Dec 2025 14:53:03" format
    local day, monthName, year = dateStr:match("(%d+)%s+(%a+)%s+(%d+)")
    if not day or not monthName or not year then
        return dateStr, nil
    end

    local month = months[monthName]
    if not month then
        return dateStr, nil
    end

    -- Format nice date
    local niceDate = string.format("%s %d", monthName, tonumber(day))

    -- Calculate days ago
    local now = os.time()
    local emailTime = os.time({year = tonumber(year), month = month, day = tonumber(day), hour = 12})
    local diffSeconds = now - emailTime
    local diffDays = math.floor(diffSeconds / 86400)

    local daysAgoStr
    if diffDays == 0 then
        daysAgoStr = "Today"
    elseif diffDays == 1 then
        daysAgoStr = "Yesterday"
    elseif diffDays < 0 then
        daysAgoStr = "Future"
    else
        daysAgoStr = string.format("%d days ago", diffDays)
    end

    return niceDate, daysAgoStr
end

local function wrapText(text, maxWidth, fontSize)
    if not text or text == "" then return {""} end

    local lines = {}
    local charsPerLine = math.floor(maxWidth / (fontSize * 0.6))
    if charsPerLine < 20 then charsPerLine = 20 end

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line == "" then
            table.insert(lines, "")
        else
            local words = {}
            for word in line:gmatch("%S+") do
                table.insert(words, word)
            end

            if #words == 0 then
                table.insert(lines, "")
            else
                local currentLine = ""
                for _, word in ipairs(words) do
                    local testLine = currentLine == "" and word or (currentLine .. " " .. word)
                    if #testLine > charsPerLine then
                        if currentLine ~= "" then
                            table.insert(lines, currentLine)
                        end
                        while #word > charsPerLine do
                            table.insert(lines, word:sub(1, charsPerLine))
                            word = word:sub(charsPerLine + 1)
                        end
                        currentLine = word
                    else
                        currentLine = testLine
                    end
                end
                if currentLine ~= "" then
                    table.insert(lines, currentLine)
                end
            end
        end
    end

    return #lines > 0 and lines or {""}
end

local function getMedalCounts()
    -- Calculate medals from total triaged
    local totalBronze = math.floor(state.triaged / 10)
    local gold = math.floor(totalBronze / (BRONZE_PER_SILVER * SILVER_PER_GOLD))
    local remainingAfterGold = totalBronze - (gold * BRONZE_PER_SILVER * SILVER_PER_GOLD)
    local silver = math.floor(remainingAfterGold / BRONZE_PER_SILVER)
    local bronze = remainingAfterGold - (silver * BRONZE_PER_SILVER)
    return bronze, silver, gold
end

local function getBatteryProgress()
    -- Progress toward next bronze medal (always 0-10)
    local progressInCurrentTen = state.triaged % 10
    return progressInCurrentTen, 10, progressInCurrentTen / 10
end

local function renderBattery(canvas, x, y, width, height, elementIndex)
    -- Horizontal battery
    local batteryHeight = height
    local capWidth = 14
    local capHeight = batteryHeight * 0.5
    local cornerRadius = 6
    local wallThickness = 3

    -- Get medals
    local bronze, silver, gold = getMedalCounts()

    -- Medal display area on left
    local medalAreaWidth = 120
    local medalText = ""
    if gold > 0 then medalText = medalText .. string.rep("🥇", gold) end
    if silver > 0 then medalText = medalText .. string.rep("🥈", silver) end
    if bronze > 0 then medalText = medalText .. string.rep("🥉", bronze) end

    if #medalText > 0 then
        canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new(medalText, {
                font = {name = "Apple Color Emoji", size = 22},
                paragraphStyle = {alignment = "left"},
            }),
            frame = {x = x, y = y + (batteryHeight - 28) / 2, w = medalAreaWidth, h = 32},
        }
        elementIndex = elementIndex + 1
    end

    -- Battery starts after medal area
    local batteryX = x + medalAreaWidth + 10
    local batteryWidth = width - medalAreaWidth - 10 - capWidth
    local bodyWidth = batteryWidth

    canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = batteryX, y = y, w = bodyWidth, h = batteryHeight},
        fillColor = {red = 0.1, green = 0.1, blue = 0.12, alpha = 1},
        roundedRectRadii = {xRadius = cornerRadius, yRadius = cornerRadius},
    }
    elementIndex = elementIndex + 1

    -- Battery border
    canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = batteryX, y = y, w = bodyWidth, h = batteryHeight},
        strokeColor = {red = 0.4, green = 0.4, blue = 0.45, alpha = 1},
        strokeWidth = wallThickness,
        fillColor = {red = 0, green = 0, blue = 0, alpha = 0},
        roundedRectRadii = {xRadius = cornerRadius, yRadius = cornerRadius},
    }
    elementIndex = elementIndex + 1

    -- Battery cap (nub on right)
    canvas[elementIndex] = {
        type = "rectangle",
        frame = {
            x = batteryX + bodyWidth - 2,
            y = y + (batteryHeight - capHeight) / 2,
            w = capWidth,
            h = capHeight
        },
        fillColor = {red = 0.3, green = 0.3, blue = 0.35, alpha = 1},
        roundedRectRadii = {xRadius = 4, yRadius = 4},
    }
    elementIndex = elementIndex + 1

    -- Get progress (always toward next 10)
    local current, target, progress = getBatteryProgress()

    -- Purple liquid fill (from left)
    local innerPadding = wallThickness + 2
    local innerWidth = bodyWidth - innerPadding * 2
    local innerHeight = batteryHeight - innerPadding * 2
    local fillWidth = innerWidth * progress

    if progress > 0 then
        -- Main fill
        canvas[elementIndex] = {
            type = "rectangle",
            frame = {
                x = batteryX + innerPadding,
                y = y + innerPadding,
                w = fillWidth,
                h = innerHeight
            },
            fillColor = GREEN_DARK,
            roundedRectRadii = {xRadius = 4, yRadius = 4},
        }
        elementIndex = elementIndex + 1

        -- Highlight (lighter green on top for 3D effect)
        local highlightHeight = innerHeight * 0.35
        canvas[elementIndex] = {
            type = "rectangle",
            frame = {
                x = batteryX + innerPadding + 2,
                y = y + innerPadding + 2,
                w = math.max(0, fillWidth - 4),
                h = highlightHeight
            },
            fillColor = GREEN_LIGHT,
            roundedRectRadii = {xRadius = 3, yRadius = 3},
        }
        elementIndex = elementIndex + 1
    end

    -- Progress text (centered in battery) - show X/10 toward next medal
    canvas[elementIndex] = {
        type = "text",
        text = hs.styledtext.new(string.format("%d / %d  🥉", current, target), {
            font = {name = "Helvetica Neue Bold", size = 16},
            color = {red = 1, green = 1, blue = 1, alpha = 0.95},
            paragraphStyle = {alignment = "center"},
        }),
        frame = {x = batteryX, y = y + (batteryHeight - 20) / 2, w = bodyWidth, h = 24},
    }
    elementIndex = elementIndex + 1

    return elementIndex
end

-----------------------------------------------------------
-- RENDERING
-----------------------------------------------------------

local function createCanvas()
    if state.canvas then
        state.canvas:delete()
    end

    local screen = hs.screen.mainScreen():fullFrame()
    -- True fullscreen - edge to edge
    local width = screen.w
    local height = screen.h
    local x = screen.x
    local y = screen.y

    state.canvas = hs.canvas.new({x = x, y = y, w = width, h = height})
    state.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    state.canvas:level(hs.canvas.windowLevels.overlay)
    state.canvas:canvasMouseEvents(true, true)
    state.canvas:clickActivating(false)
    state.canvasWidth = width
    state.canvasHeight = height
end

render = function()
    if not state.visible then return end

    createCanvas()

    local width = state.canvasWidth
    local height = state.canvasHeight
    local padding = 50  -- More padding for fullscreen
    local elementIndex = 1

    -- Background (no rounded corners - fullscreen)
    state.canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = 0, y = 0, w = width, h = height},
        fillColor = Panel.colors.background,
    }
    elementIndex = elementIndex + 1

    -- Compact header - all on one line
    local headerY = 15
    local email = state.emails[state.currentIndex]
    local remainingCount = state.total > 0 and state.total or #state.emails

    -- Single line: Title + Loading + Counts
    state.canvas[elementIndex] = {
        type = "text",
        text = hs.styledtext.new("Email Triage", {
            font = {name = "Helvetica Neue Bold", size = 18},
            color = Panel.colors.text,
        }),
        frame = {x = padding, y = headerY, w = 150, h = 24},
    }
    elementIndex = elementIndex + 1

    -- Loading spinner (inline after title)
    if state.isLoading then
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("⟳", {
                font = {name = "Helvetica Neue", size = 16},
                color = Panel.colors.accent,
            }),
            frame = {x = padding + 130, y = headerY, w = 30, h = 24},
        }
        elementIndex = elementIndex + 1
    end

    -- Counts on right side (single line)
    local cachedCount = #cache.emails
    local countsText = string.format("✓ %d done   📬 %d left   💾 %d cached", state.triaged, remainingCount, cachedCount)
    state.canvas[elementIndex] = {
        type = "text",
        text = hs.styledtext.new(countsText, {
            font = {name = "Helvetica Neue Bold", size = 18},
            color = {red = 0.7, green = 0.8, blue = 0.7, alpha = 1},
            paragraphStyle = {alignment = "right"},
        }),
        frame = {x = width - 420 - padding, y = headerY, w = 420, h = 24},
    }
    elementIndex = elementIndex + 1

    -- Separator
    local sepY = headerY + 30
    state.canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = padding, y = sepY, w = width - padding * 2, h = 1},
        fillColor = Panel.colors.separator,
    }
    elementIndex = elementIndex + 1

    -- Battery progress bar (horizontal, above content)
    local batteryY = sepY + 20
    local batteryHeight = 36
    local batteryWidth = width - padding * 2
    elementIndex = renderBattery(state.canvas, padding, batteryY, batteryWidth, batteryHeight, elementIndex)

    -- Second separator after battery
    local sepY2 = batteryY + batteryHeight + 20
    state.canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = padding, y = sepY2, w = width - padding * 2, h = 1},
        fillColor = Panel.colors.separator,
    }
    elementIndex = elementIndex + 1

    -- Content area
    local contentY = sepY2 + 25

    if state.isLoading then
        -- Loading state
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("Loading emails...", {
                font = Panel.fonts.main,
                color = Panel.colors.accent,
                paragraphStyle = {alignment = "center"},
            }),
            frame = {x = padding, y = height / 2 - 20, w = width - padding * 2, h = 40},
        }
        elementIndex = elementIndex + 1

    elseif state.error then
        -- Error state
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("Error: " .. state.error, {
                font = Panel.fonts.body,
                color = Panel.colors.danger,
                paragraphStyle = {alignment = "center"},
            }),
            frame = {x = padding, y = height / 2 - 20, w = width - padding * 2, h = 40},
        }
        elementIndex = elementIndex + 1

    elseif #state.emails == 0 then
        -- Empty inbox
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("Inbox Zero!", {
                font = Panel.fonts.title,
                color = Panel.colors.success,
                paragraphStyle = {alignment = "center"},
            }),
            frame = {x = padding, y = height / 2 - 40, w = width - padding * 2, h = 40},
        }
        elementIndex = elementIndex + 1

        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("No emails to triage. Press Escape to close.", {
                font = Panel.fonts.body,
                color = Panel.colors.textDim,
                paragraphStyle = {alignment = "center"},
            }),
            frame = {x = padding, y = height / 2, w = width - padding * 2, h = 30},
        }
        elementIndex = elementIndex + 1

    elseif email then
        -- Get rotating color for this email
        local emailColor = getCurrentEmailColor()

        -- From
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new("From:", {
                font = Panel.fonts.small,
                color = Panel.colors.textDim,
            }),
            frame = {x = padding, y = contentY, w = 50, h = 20},
        }
        elementIndex = elementIndex + 1

        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new(email["from"] or "Unknown", {
                font = Panel.fonts.body,
                color = emailColor,
            }),
            frame = {x = padding + 55, y = contentY, w = width - padding * 2 - 55, h = 20},
        }
        elementIndex = elementIndex + 1
        contentY = contentY + 28

        -- Date with calendar emoji and days ago
        local niceDate, daysAgo = parseDateAndDaysAgo(email["date"])
        local dateDisplay = "📅 "
        if niceDate then
            dateDisplay = dateDisplay .. niceDate
            if daysAgo then
                dateDisplay = dateDisplay .. "  (" .. daysAgo .. ")"
            end
        else
            dateDisplay = dateDisplay .. (email["date"] or "Unknown")
        end

        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new(dateDisplay, {
                font = Panel.fonts.body,
                color = Panel.colors.text,
            }),
            frame = {x = padding, y = contentY, w = width - padding * 2, h = 24},
        }
        elementIndex = elementIndex + 1
        contentY = contentY + 32

        -- Subject (larger, prominent, colored)
        state.canvas[elementIndex] = {
            type = "text",
            text = hs.styledtext.new(email["subject"] or "(no subject)", {
                font = Panel.fonts.main,
                color = emailColor,
            }),
            frame = {x = padding, y = contentY, w = width - padding * 2, h = 60},
        }
        elementIndex = elementIndex + 1
        contentY = contentY + 70

        -- Separator before body
        state.canvas[elementIndex] = {
            type = "rectangle",
            frame = {x = padding, y = contentY, w = width - padding * 2, h = 1},
            fillColor = Panel.colors.separator,
        }
        elementIndex = elementIndex + 1
        contentY = contentY + 10

        -- Body area dimensions (for webview)
        local bodyAreaHeight = height - contentY - 90  -- Leave room for footer
        local bodyWidth = width - padding * 2
        local body = email["body"] or ""
        local snippet = email["snippet"] or ""
        local bodyContent = (#body > 0) and body or snippet

        -- Store body area for webview positioning
        state.bodyArea = {
            x = padding,
            y = contentY,
            w = bodyWidth,
            h = bodyAreaHeight,
        }
        state.bodyContent = bodyContent
    end

    -- Footer with keyboard shortcuts - ORANGE and prominent
    local footerY = height - 80
    local orangeColor = {red = 1, green = 0.6, blue = 0, alpha = 1}
    local orangeDim = {red = 1, green = 0.5, blue = 0, alpha = 0.7}

    -- Background bar for shortcuts
    state.canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = 0, y = footerY - 10, w = width, h = 70},
        fillColor = {red = 0.15, green = 0.1, blue = 0, alpha = 0.9},
    }
    elementIndex = elementIndex + 1

    -- Top border
    state.canvas[elementIndex] = {
        type = "rectangle",
        frame = {x = 0, y = footerY - 10, w = width, h = 2},
        fillColor = orangeColor,
    }
    elementIndex = elementIndex + 1

    local shortcuts = "e Archive   t Task   x Delete   s Suppress   l Labels   ← Undo   ↑↓ Scroll   Esc Close"
    state.canvas[elementIndex] = {
        type = "text",
        text = hs.styledtext.new(shortcuts, {
            font = {name = "Menlo-Bold", size = 16},
            color = orangeColor,
            paragraphStyle = {alignment = "center"},
        }),
        frame = {x = padding, y = footerY + 8, w = width - padding * 2, h = 30},
    }
    elementIndex = elementIndex + 1

    state.canvas:show()

    -- Render email body in webview (after canvas so we have body area)
    if state.bodyArea and state.bodyContent then
        local screen = hs.screen.mainScreen():fullFrame()

        -- Create or update webview
        if not state.webview then
            state.webview = hs.webview.new({
                x = screen.x + state.bodyArea.x,
                y = screen.y + state.bodyArea.y,
                w = state.bodyArea.w,
                h = state.bodyArea.h,
            })
            state.webview:windowStyle({"borderless", "utility"})
            state.webview:level(hs.canvas.windowLevels.overlay + 1)
            state.webview:allowTextEntry(false)
            state.webview:allowGestures(true)
        else
            state.webview:frame({
                x = screen.x + state.bodyArea.x,
                y = screen.y + state.bodyArea.y,
                w = state.bodyArea.w,
                h = state.bodyArea.h,
            })
        end

        -- Wrap content in dark-themed HTML
        local htmlTemplate = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        * { box-sizing: border-box; }
        html, body {
            margin: 0;
            padding: 0;
            background: #1a1a1a;
            color: #e0e0e0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 14px;
            line-height: 1.5;
        }
        body {
            padding: 15px;
            overflow-y: auto;
        }
        a { color: #5cb3ff; }
        img { max-width: 100%%; height: auto; }
        table { border-collapse: collapse; }
        td, th { padding: 4px 8px; }
        pre, code { background: #2a2a2a; padding: 2px 6px; border-radius: 3px; }
        blockquote { border-left: 3px solid #444; margin-left: 0; padding-left: 15px; color: #aaa; }
        hr { border: none; border-top: 1px solid #333; }
    </style>
</head>
<body>
%s
</body>
</html>
]]

        -- Convert newlines to <br> for plain text emails
        local bodyForHtml = state.bodyContent:gsub("\n", "<br>\n")
        local htmlContent = string.format(htmlTemplate, bodyForHtml)
        state.webview:html(htmlContent)
        state.webview:show()
    elseif state.webview then
        state.webview:hide()
    end
end

-----------------------------------------------------------
-- API CALLS
-----------------------------------------------------------

local function runTask(taskKey, command, args, callback)
    -- Terminate existing task of this type
    if state[taskKey] then
        state[taskKey]:terminate()
    end

    local fullArgs = {command}
    if args then
        for _, arg in ipairs(args) do
            table.insert(fullArgs, arg)
        end
    end


    state[taskKey] = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        state[taskKey] = nil

        if exitCode ~= 0 then
            local ok, errData = pcall(hs.json.decode, stdErr)
            if ok and errData and errData.error then
                state.error = errData.error
            else
                state.error = stdErr or "Unknown error"
            end
            if callback then callback(false) end
            return
        end

        local ok, data = pcall(hs.json.decode, stdOut)
        if not ok or not data then
            state.error = "Failed to parse response"
            if callback then callback(false) end
            return
        end

        if not data.success then
            state.error = data.error or "Unknown error"
            if callback then callback(false) end
            return
        end

        state.error = nil
        if callback then callback(true, data) end
    end, fullArgs)

    state[taskKey]:start()
end

-- Core fetch function with deduplication
local function doFetch(callback, maxCount)
    if cache.prefetchTask then return end

    local fetchMax = maxCount or MAX_EMAILS
    cache.prefetchTask = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        cache.prefetchTask = nil
        cache.lastFetch = os.time()

        if exitCode == 0 then
            local ok, data = pcall(hs.json.decode, stdOut)
            if ok and data and data.success and data.emails then
                -- Merge new emails into cache (deduplicate)
                local existingIds = {}
                for _, e in ipairs(cache.emails) do
                    existingIds[e.id] = true
                end
                for _, e in ipairs(data.emails) do
                    if not existingIds[e.id] then
                        table.insert(cache.emails, e)
                    end
                end
                cache.total = data.total or cache.total
                -- Sort by date after merging
                sortEmailsByDate(cache.emails)
                -- Save to disk for offline use
                saveCacheToDisk()

                -- Also update state if visible
                if state.visible then
                    existingIds = {}
                    for _, e in ipairs(state.emails) do
                        existingIds[e.id] = true
                    end
                    for _, e in ipairs(data.emails) do
                        if not existingIds[e.id] then
                            table.insert(state.emails, e)
                        end
                    end
                    state.total = data.total or state.total
                    -- Sort by date after merging
                    sortEmailsByDate(state.emails)
                    -- Clear loading state and re-render after async fetch
                    state.isLoading = false
                    render()
                end
            end
        end

        if callback then callback() end
    end, {"fetch", "--max", tostring(fetchMax)})
    cache.prefetchTask:start()
end

-- Debounced prefetch - schedules a fetch after debounce period
schedulePrefetch = function()
    -- Don't stack up fetches
    if cache.prefetchTask then return end

    -- Cancel existing timer
    if cache.fetchTimer then
        cache.fetchTimer:stop()
        cache.fetchTimer = nil
    end

    -- Always try to stay ahead - fetch if below threshold
    local emailCount = state.visible and #state.emails or #cache.emails
    if emailCount >= REFETCH_THRESHOLD then
        return  -- We have enough emails
    end

    -- Schedule fetch after debounce
    cache.fetchTimer = hs.timer.doAfter(DEBOUNCE_SECONDS, function()
        cache.fetchTimer = nil
        doFetch(function()
            -- Chain another fetch if still low
            schedulePrefetch()
        end)
    end)
end

-- Immediate prefetch (no debounce) - for startup
local function prefetch()
    -- Quick initial fetch, then chain larger background fetch
    doFetch(function()
        -- After initial fetch completes, get the rest for offline use
        doFetch(nil, MAX_EMAILS)
    end, INITIAL_FETCH)
end

local function fetchEmails()
    -- Step 1: Load from disk cache synchronously (instant!)
    local output, status = hs.execute(HELPER_PATH .. " cache-load", true)
    if status and output then
        output = output:gsub("^[^{]*", "")
        local ok, data = pcall(hs.json.decode, output)
        -- Only use cache if total > 0 and emails exist (prevents stale cache)
        if ok and data and data.emails and #data.emails > 0 and (data.total or 0) > 0 then
            state.emails = data.emails
            cache.emails = data.emails
            sortEmailsByDate(state.emails)
            state.total = data.total or #state.emails
            cache.total = state.total
            state.currentIndex = 1
            state.scrollOffset = 0
            state.isLoading = false
            render()
            -- Step 2: Background refresh (non-blocking)
            local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
                if exitCode == 0 then
                    local out = stdOut:gsub("^[^{]*", "")
                    local ok2, data2 = pcall(hs.json.decode, out)
                    if ok2 and data2 and data2.success then
                        -- Replace with actual inbox state (not merge)
                        -- This ensures stale cached emails are removed
                        local freshEmails = data2.emails or {}
                        local freshTotal = data2.total or 0

                        -- Build set of IDs that are actually in inbox
                        local freshIds = {}
                        for _, e in ipairs(freshEmails) do
                            freshIds[e.id] = true
                        end

                        -- Filter state.emails to only keep what's still in inbox
                        local filteredEmails = {}
                        for _, e in ipairs(state.emails) do
                            if freshIds[e.id] then
                                table.insert(filteredEmails, e)
                            end
                        end

                        -- Add any new emails from fresh fetch
                        local existingIds = {}
                        for _, e in ipairs(filteredEmails) do
                            existingIds[e.id] = true
                        end
                        for _, e in ipairs(freshEmails) do
                            if not existingIds[e.id] then
                                table.insert(filteredEmails, e)
                            end
                        end

                        state.emails = filteredEmails
                        cache.emails = filteredEmails
                        sortEmailsByDate(state.emails)
                        sortEmailsByDate(cache.emails)
                        state.total = freshTotal
                        cache.total = freshTotal

                        -- Adjust index if needed
                        if state.currentIndex > #state.emails then
                            state.currentIndex = math.max(1, #state.emails)
                        end

                        render()
                        saveCacheToDisk()
                    end
                end
            end, {"fetch", "--max", tostring(MAX_EMAILS)})
            task:start()
            return
        end
    end

    -- Fallback: No disk cache, show loading and fetch
    state.isLoading = true
    state.error = nil
    render()
    local task = hs.task.new(HELPER_PATH, function(exitCode, stdOut, stdErr)
        state.isLoading = false
        if exitCode ~= 0 then
            state.error = "Fetch failed"
            render()
            return
        end
        local out = stdOut:gsub("^[^{]*", "")
        local ok, data = pcall(hs.json.decode, out)
        if ok and data and data.success and data.emails then
            state.emails = data.emails
            cache.emails = data.emails
            sortEmailsByDate(state.emails)
            state.total = data.total or #state.emails
            cache.total = state.total
            state.currentIndex = 1
            state.scrollOffset = 0
            saveCacheToDisk()
        else
            state.error = "Failed to parse emails"
        end
        render()
    end, {"fetch", "--max", tostring(MAX_EMAILS)})
    task:start()
end

local function fetchMoreEmails()
    schedulePrefetch()
end

local function performAction(action)
    local email = state.emails[state.currentIndex]
    if not email then
        -- No emails left, fetch more
        state.isLoading = true
        render()
        fetchMoreEmails(true)
        return
    end

    -- Save to undo stack before removing
    table.insert(state.undoStack, {
        email = email,
        action = action,
        index = state.currentIndex,
    })

    -- Optimistically update UI immediately (no loading state!)
    state.triaged = state.triaged + 1
    if state.total > 0 then
        state.total = state.total - 1
    end
    if cache.total > 0 then
        cache.total = cache.total - 1
    end

    -- Play faster music every MUSIC_MILESTONE emails
    if state.triaged > 0 and state.triaged % MUSIC_MILESTONE == 0 then
        playMusicForMilestone(state.triaged)
    end

    -- Remove from list and cache immediately
    local emailId = email.id
    table.remove(state.emails, state.currentIndex)
    for i, e in ipairs(cache.emails) do
        if e.id == emailId then
            table.remove(cache.emails, i)
            break
        end
    end

    -- Adjust index
    if state.currentIndex > #state.emails then
        state.currentIndex = math.max(1, #state.emails)
    end
    state.scrollOffset = 0

    -- Show next email immediately
    render()

    -- Always trigger prefetch to stay ahead
    schedulePrefetch()

    -- Save cache to disk after each action
    saveCacheToDisk()

    -- If offline, queue the action
    if not cache.isOnline then
        queueOfflineAction(email, action)
        return
    end

    -- Fire API call in background (don't wait for it)
    runTask("actionTask", action, {emailId}, function(success)
        if not success then
            -- API failed - queue for later and mark offline
            cache.isOnline = false
            queueOfflineAction(email, action)
            -- Clear the error since we handled it by queuing
            state.error = nil
            render()  -- Update UI to show offline status
        end
    end)
end

local function performUndo()
    if #state.undoStack == 0 then
        return  -- Nothing to undo
    end

    -- Pop from undo stack
    local undoItem = table.remove(state.undoStack)
    local email = undoItem.email
    local action = undoItem.action
    local originalIndex = undoItem.index

    -- Restore email to list at original position
    local insertIndex = math.min(originalIndex, #state.emails + 1)
    table.insert(state.emails, insertIndex, email)
    table.insert(cache.emails, email)
    sortEmailsByDate(cache.emails)

    -- Update counts
    state.triaged = math.max(0, state.triaged - 1)
    state.total = state.total + 1
    cache.total = cache.total + 1

    -- Move to the restored email
    state.currentIndex = insertIndex
    state.scrollOffset = 0

    -- Render immediately
    render()

    -- Reverse the action in the background
    local reverseAction = nil
    if action == "archive" then
        reverseAction = "unarchive"
    elseif action == "delete" then
        reverseAction = "undelete"
    elseif action == "task" or action == "suppress" then
        -- Can't easily undo task creation, but at least restore to inbox
        reverseAction = "unarchive"
    end

    if reverseAction then
        runTask("actionTask", reverseAction, {email.id}, function(success)
            if not success then
                -- If undo fails, we still keep it in the UI
                state.error = nil
            end
        end)
    end
end

-----------------------------------------------------------
-- KEYBOARD HANDLING
-----------------------------------------------------------

-- Map key codes to characters for label hints
local KEY_TO_CHAR = {
    [0] = "a", [11] = "b", [8] = "c", [2] = "d", [3] = "f",
    [5] = "g", [4] = "h", [34] = "i", [38] = "j", [40] = "k",
    [46] = "m", [45] = "n", [31] = "o", [35] = "p", [12] = "q",
    [15] = "r", [32] = "u", [9] = "v", [13] = "w", [6] = "y",
    [44] = "z",
    [18] = "1", [19] = "2", [20] = "3", [21] = "4", [23] = "5",
    [22] = "6", [26] = "7", [28] = "8", [25] = "9", [29] = "0",
}

local function handleKeyPress(event)
    if not state.visible then return false end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    -- Escape - close label picker or main panel
    if keyCode == 53 then
        if state.labelPickerVisible then
            hideLabelPicker()
        else
            M.hide()
        end
        return true
    end

    -- If label picker is visible, handle label selection
    if state.labelPickerVisible then
        local char = KEY_TO_CHAR[keyCode]
        if char then
            local hintIndex = LABEL_HINTS:find(char)
            if hintIndex then
                toggleLabel(hintIndex)
                return true
            end
        end
        return false
    end

    -- Don't handle keys while loading
    if state.isLoading then return false end

    -- l - Show label picker
    if keyCode == 37 then
        fetchLabelsAndShow()
        return true
    end

    -- e - Archive + Mark as Read (like Gmail)
    if keyCode == 14 then
        performAction("archive")
        return true
    end

    -- t - Create Todoist task + Archive
    if keyCode == 17 then
        performAction("task")
        return true
    end

    -- x - Delete (like Gmail)
    if keyCode == 7 then
        performAction("delete")
        return true
    end

    -- s - Suppress (unsubscribe task + archive)
    if keyCode == 1 then
        performAction("suppress")
        return true
    end

    -- Left arrow or backspace - Undo last action
    if keyCode == 123 or keyCode == 51 then
        performUndo()
        return true
    end

    -- Arrow keys for scrolling webview
    if state.webview then
        -- Down arrow - scroll down
        if keyCode == 125 then
            state.webview:evaluateJavaScript("window.scrollBy(0, 100)")
            return true
        end
        -- Up arrow - scroll up
        if keyCode == 126 then
            state.webview:evaluateJavaScript("window.scrollBy(0, -100)")
            return true
        end
        -- Page Down
        if keyCode == 121 then
            state.webview:evaluateJavaScript("window.scrollBy(0, 400)")
            return true
        end
        -- Page Up
        if keyCode == 116 then
            state.webview:evaluateJavaScript("window.scrollBy(0, -400)")
            return true
        end
        -- j - scroll down (vim style)
        if keyCode == 38 then
            state.webview:evaluateJavaScript("window.scrollBy(0, 100)")
            return true
        end
        -- k - scroll up (vim style)
        if keyCode == 40 then
            state.webview:evaluateJavaScript("window.scrollBy(0, -100)")
            return true
        end
    end

    return false
end

-----------------------------------------------------------
-- PUBLIC API
-----------------------------------------------------------

function M.show()
    if state.visible then return end

    state.visible = true
    state.emails = {}
    state.currentIndex = 1
    state.scrollOffset = 0
    state.error = nil
    state.triaged = 0  -- Reset session counter
    state.undoStack = {}  -- Reset undo stack

    -- Set up keyboard handler
    if state.keyTap then
        state.keyTap:stop()
    end
    state.keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, handleKeyPress)
    state.keyTap:start()

    -- Fetch emails
    fetchEmails()
end

function M.hide()
    if not state.visible then return end

    state.visible = false

    if state.keyTap then
        state.keyTap:stop()
        state.keyTap = nil
    end

    if state.actionTask then
        state.actionTask:terminate()
        state.actionTask = nil
    end

    if state.fetchTask then
        state.fetchTask:terminate()
        state.fetchTask = nil
    end

    -- Clean up timers
    if cache.fetchTimer then
        cache.fetchTimer:stop()
        cache.fetchTimer = nil
    end

    -- Clean up label picker
    hideLabelPicker()

    -- Clean up webview
    if state.webview then
        state.webview:delete()
        state.webview = nil
    end

    if state.canvas then
        state.canvas:delete()
        state.canvas = nil
    end

    -- Keep prefetching in background for next time
    prefetch()
end

function M.toggle()
    if state.visible then
        M.hide()
    else
        M.show()
    end
end

function M.isVisible()
    return state.visible
end

-- Expose prefetch for external calls
function M.prefetch()
    prefetch()
end

-- Initialize offline support when module loads
loadCacheFromDisk()   -- Load any cached emails from disk
checkOnline()         -- Check initial connectivity status
startSyncTimer()      -- Start periodic sync attempts
-- Note: We don't prefetch at startup - fetch happens when UI is opened

return M
