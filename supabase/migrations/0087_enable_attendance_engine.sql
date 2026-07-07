-- Phase 5/8 activation: the join-link UI, dashboard links, and email
-- templates are now confirmed live in production, so it's safe to switch
-- session completion over to verified attendance and start evaluating
-- grace periods. Both steps are done together, per the plan in
-- 0079_attendance_tracking.sql and 0080_attendance_engine_toggle.sql.

update platform_settings set value = 'true' where key = 'attendance_engine_enabled';

select cron.schedule('attendance-grace-period', '*/5 * * * *',
  $$ select evaluate_attendance_after_grace_period() $$);
