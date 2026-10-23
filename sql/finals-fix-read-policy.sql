-- Публичная база мессенджера. Чинит создание финала (INSERT ... RETURNING). Безопасно повторять.
drop policy if exists fs_read on finals_sessions;
create policy fs_read on finals_sessions for select using (host_id = auth.uid() or finals_is_member(id));
