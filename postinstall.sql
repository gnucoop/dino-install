-- =============================================================================
-- Dino post-install seed — run once, automatically, by the `postinstall` service
-- after Hasura (public.*) and auth (auth.*) migrations have been applied.
--
-- Idempotent: everything is guarded by `IF NOT EXISTS (... user_role)`, so
-- re-running on later `docker compose up` is a harmless no-op.
--
-- Values are passed as psql variables (quote-safe, no rendering needed):
--   :client_email  :client_password  :client_display_name
-- psql does not interpolate :vars inside a DO $$...$$ block, so they are stashed
-- as session settings here and read back with current_setting() inside the block.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

SELECT set_config('dino.client_email',        :'client_email',        false);
SELECT set_config('dino.client_password',     :'client_password',     false);
SELECT set_config('dino.client_display_name', :'client_display_name', false);

DO $$
DECLARE
  _user_id  uuid;
  _group_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_role) THEN

    -- 1. Default roles ------------------------------------------------------
    INSERT INTO public.user_role ("roleName", "rolePermissions") VALUES
      ('admin',      '{ "form_data": [ "all" ], "form_schema": [ "all" ], "report_data": [ "all" ], "report_schema": [ "all" ] }'),
      ('supervisor', '{ "form_data": [ "all" ], "form_schema": [ "all" ], "report_data": [ "all" ], "report_schema": [ "all" ] }'),
      ('collector',  '{ "form_data": [ "all" ], "form_schema": [ "view" ], "report_data": [ "all" ], "report_schema": [ "view" ] }'),
      ('guest',      '{ "form_data": [ "view", "print" ], "form_schema": [ "view" ], "report_data": [ "view", "print" ], "report_schema": [ "view" ] }');

    -- 2. Admin group (capture its id) --------------------------------------
    INSERT INTO public.user_group (
      "user_role_ref_id",
      "groupFormSchemaIds",
      "groupReportSchemaIds",
      "groupName",
      "area_ref_id",
      "location_ref_id",
      "organization_ref_id",
      "project_ref_id",
      "case_ref_id",
      "form_status_ref_id"
    ) VALUES (
      (SELECT "id" FROM public.user_role WHERE "roleName" = 'admin'),
      '["all"]', '["all"]', 'Admin',
      '["all"]', '["all"]', '["all"]', '["all"]', '["all"]', '["all"]'
    )
    RETURNING "id" INTO _group_id;

    -- 3. Web login user in auth.users (capture its id) ---------------------
    -- Ensure the 'admin' auth role exists (FK target for auth.user_roles);
    -- nhost seeds only 'user'/'me'/'anonymous' by default.
    INSERT INTO auth.roles (role) VALUES ('admin') ON CONFLICT DO NOTHING;

    INSERT INTO auth.users (
      email, password_hash, default_role, locale,
      email_verified, phone_number_verified, is_anonymous, disabled,
      metadata, display_name, avatar_url
    ) VALUES (
      current_setting('dino.client_email'),
      crypt(current_setting('dino.client_password'), gen_salt('bf')),
      'user', 'en', true, false, false, false,
      jsonb_build_object('firstName', current_setting('dino.client_display_name'), 'lastName', 'Admin'),
      current_setting('dino.client_display_name'), ''
    )
    RETURNING id INTO _user_id;

    -- 4. Role mapping for the login user -----------------------------------
    INSERT INTO auth.user_roles (user_id, role)
    SELECT _user_id, unnest(ARRAY['user', 'admin']);

    -- 5. Admin user_data, linked to the auth user and the Admin group ------
    INSERT INTO public.user_data (
      "full_name", "email", "user_auth_ref_id", "user_group_ids"
    ) VALUES (
      current_setting('dino.client_display_name'), current_setting('dino.client_email'),
      _user_id, json_build_array(_group_id)
    );

    -- 6. Anonymous user ----------------------------------------------------
    INSERT INTO public.user_data ("full_name") VALUES ('dino_anonymous_user');

  END IF;
END $$;
