-- All tunable constants live here so other modules can `require("config")`
-- and read them. Edit values here, restart the mod, no other file needs to
-- change.

return {
    -- Single source of truth for the mod version. Bump this when releasing;
    -- settings.lua propagates it to SN2ModSettings, main.lua logs it on load,
    -- and the release zip filename should match.
    VERSION              = "1.3.1",

    -- Loop / cache timing
    POLL_MS              = 500,
    CACHE_REFRESH_MS     = 2000,
    SCAN_LOG_PERIOD_MS   = 3000,
    CLEANUP_DURATION_MS  = 15000,

    -- Base detection. The player is treated as "in this base" if any
    -- support pillar of that base is within SUPPORT_MAX_DIST_M. A locker
    -- is claimed by its nearest support's base if that support is within
    -- LOCKER_TO_SUPPORT_M. Both are generous to handle long corridors and
    -- large rooms; we still rely on BaseGUID for the actual identity check.
    SUPPORT_MAX_DIST_M   = 100,
    LOCKER_TO_SUPPORT_M  = 50,

    -- Fallback radius detection (used when no support actors are reachable)
    BASE_DETECT_RADIUS_M = 20,
    LOCKER_RADIUS_M      = 35,

    -- HUD layout
    TITLE                = "Alterra Audit",
    SHOW_HEADER          = false,
    HUD_SIDE             = "right",   -- "left" or "right"
    MARGIN_X             = 24,
    MARGIN_Y             = 24,
    ICON_SIZE            = 24,
    HEADER_ICON_SIZE     = 28,
    TEXT_SIZE            = 10,
    HEADER_TEXT_SIZE     = 12,
    ROW_GAP_PX           = 1,
    GROUP_GAP_PX         = 4,
    ICON_GAP_PX          = 5,
    ROW_POOL_PER_GROUP   = 15,   -- max item rows shown per group

    -- Group ordering and labels. Keys must match the strings produced by
    -- items.lua group_from_tag() — see GROUP_PRETTY there.
    GROUP_ORDER          = { "Minerals", "Flora", "Fauna", "Fuel", "Crafted" },

    -- Colours
    TEXT_COLOR           = { R = 0.85, G = 0.96, B = 1.00, A = 1.00 },
    TITLE_COLOR          = { R = 0.40, G = 0.90, B = 1.00, A = 1.00 },
    DIM_COLOR            = { R = 0.65, G = 0.78, B = 0.85, A = 1.00 },
    GROUP_LABEL_COLOR    = { R = 1.00, G = 0.85, B = 0.45, A = 1.00 },

    -- ESlateVisibility: Visible=0, Collapsed=1, Hidden=2,
    -- HitTestInvisible=3, SelfHitTestInvisible=4
    -- Root uses SelfHitTestInvisible so gameplay clicks pass through except
    -- on widgets explicitly set to Visible (the group header buttons).
    VIS_DRAW             = 3,      -- item rows: render only, no clicks
    VIS_CLICKABLE        = 0,      -- group headers: render AND clickable
    VIS_ROOT             = 4,      -- root canvas: SelfHitTestInvisible
    VIS_COLLAPSED        = 1,

    -- Widget identity
    WIDGET_NAME_PREFIX   = "AlterraAuditHUD",

    -- Logging
    LOG_PREFIX           = "[AlterraAudit]",
}
