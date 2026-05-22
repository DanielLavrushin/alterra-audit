-- All tunable constants live here so other modules can `require("config")`
-- and read them. Edit values here, restart the mod, no other file needs to
-- change.

return {
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
    TEXT_SIZE            = 10,
    ROW_GAP_PX           = 1,
    ICON_GAP_PX          = 5,
    ROW_POOL             = 50,

    -- Colours
    TEXT_COLOR           = { R = 0.85, G = 0.96, B = 1.00, A = 1.00 },
    TITLE_COLOR          = { R = 0.40, G = 0.90, B = 1.00, A = 1.00 },
    DIM_COLOR            = { R = 0.65, G = 0.78, B = 0.85, A = 1.00 },

    -- ESlateVisibility: Visible=0, Collapsed=1, Hidden=2,
    -- HitTestInvisible=3, SelfHitTestInvisible=4
    VIS_DRAW             = 3,
    VIS_COLLAPSED        = 1,

    -- Widget identity
    WIDGET_NAME_PREFIX   = "AlterraAuditHUD",

    -- Logging
    LOG_PREFIX           = "[AlterraAudit]",
}
