-- widen reschedule_offers status set for the v2 reschedule rework
alter table reschedule_offers drop constraint if exists reschedule_offers_status_check;
alter table reschedule_offers add constraint reschedule_offers_status_check
  check (status in ('pending','mentee_selected','accepted','declined','rejected','superseded','expired'));
