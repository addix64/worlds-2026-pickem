-- Connexion Discord et liste privée des pseudos pour l'organisateur.
-- Exécuter après supabase-schema.sql et supabase-addix-organisateur-joueur.sql.

create table if not exists public.discord_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  discord_username text not null,
  discord_global_name text,
  updated_at timestamptz not null default now()
);

alter table public.discord_accounts enable row level security;
revoke all on table public.discord_accounts from public, anon, authenticated;
grant select on table public.discord_accounts to authenticated;

drop policy if exists "worlds admins can view Discord accounts" on public.discord_accounts;
create policy "worlds admins can view Discord accounts"
  on public.discord_accounts
  for select
  to authenticated
  using ((select public.is_worlds_admin()));

-- Lit les données vérifiées depuis l'identité OAuth Discord, pas depuis un champ modifiable du profil joueur.
create or replace function public.sync_worlds_discord_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_global_name text;
begin
  if new.provider <> 'discord' then
    return new;
  end if;

  v_username := coalesce(
    nullif(trim(new.identity_data ->> 'username'), ''),
    nullif(trim(new.identity_data ->> 'preferred_username'), ''),
    nullif(trim(new.identity_data ->> 'full_name'), ''),
    nullif(trim(new.identity_data ->> 'name'), '')
  );
  v_global_name := coalesce(
    nullif(trim(new.identity_data ->> 'global_name'), ''),
    nullif(trim(new.identity_data -> 'custom_claims' ->> 'global_name'), '')
  );

  if v_username is null then
    return new;
  end if;

  insert into public.discord_accounts (user_id, discord_username, discord_global_name, updated_at)
  values (new.user_id, v_username, v_global_name, now())
  on conflict (user_id) do update
    set discord_username = excluded.discord_username,
        discord_global_name = excluded.discord_global_name,
        updated_at = now();

  -- Les comptes créés par Discord reçoivent un alias de classement distinct.
  -- Le pseudo Discord reste privé dans discord_accounts.
  update public.profiles
  set display_name = 'Joueur-' || substring(replace(new.user_id::text, '-', '') from 1 for 6)
  where id = new.user_id
    and display_name = 'Joueur';

  return new;
end;
$$;

drop trigger if exists worlds_discord_identity_sync on auth.identities;
create trigger worlds_discord_identity_sync
  after insert or update of identity_data on auth.identities
  for each row execute procedure public.sync_worlds_discord_account();

-- Récupère également les joueurs ayant déjà lié Discord avant cette migration.
insert into public.discord_accounts (user_id, discord_username, discord_global_name, updated_at)
select distinct on (i.user_id)
  i.user_id,
  coalesce(
    nullif(trim(i.identity_data ->> 'username'), ''),
    nullif(trim(i.identity_data ->> 'preferred_username'), ''),
    nullif(trim(i.identity_data ->> 'full_name'), ''),
    nullif(trim(i.identity_data ->> 'name'), '')
  ),
  coalesce(
    nullif(trim(i.identity_data ->> 'global_name'), ''),
    nullif(trim(i.identity_data -> 'custom_claims' ->> 'global_name'), '')
  ),
  now()
from auth.identities as i
where i.provider = 'discord'
  and coalesce(
    nullif(trim(i.identity_data ->> 'username'), ''),
    nullif(trim(i.identity_data ->> 'preferred_username'), ''),
    nullif(trim(i.identity_data ->> 'full_name'), ''),
    nullif(trim(i.identity_data ->> 'name'), '')
  ) is not null
order by i.user_id, i.updated_at desc nulls last, i.created_at desc nulls last
on conflict (user_id) do update
  set discord_username = excluded.discord_username,
      discord_global_name = excluded.discord_global_name,
      updated_at = now();
