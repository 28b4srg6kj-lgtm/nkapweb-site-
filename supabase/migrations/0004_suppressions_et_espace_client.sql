-- 0004 · Suppression contrôlée des encaissements et commandes saisis à la main, espace client.
-- À exécuter dans Supabase > SQL Editor après 0001, 0002 et 0003.
--
-- 1. Un administrateur peut supprimer un encaissement (et ses écritures) ou une commande entière
--    (paiements, écritures de vente et d'imputation). Chaque suppression est tracée dans
--    public.suppressions avec la copie complète des données retirées.
--    Règle : un encaissement d'une commande déjà facturée ne se supprime pas seul (les écritures
--    d'imputation 4191 → 4111 dépendent de lui) : on supprime la commande entière ou on contre-passe.
-- 2. Les clients lisent leurs propres commandes et paiements (correspondance par e-mail de connexion).
-- 3. Les commandes portent l'adresse du site livré (site_url) pour l'espace client.

-- ---------- 1. Trace des suppressions ----------
create table if not exists public.suppressions (
  id         bigint generated always as identity primary key,
  objet      text not null check (objet in ('paiement', 'commande')),
  objet_id   bigint not null,
  donnees    jsonb not null,
  ecritures  jsonb not null default '[]'::jsonb,
  motif      text,
  par        uuid default auth.uid(),
  quand      timestamptz not null default now()
);
alter table public.suppressions enable row level security;
drop policy if exists admin_lit_suppressions on public.suppressions;
create policy admin_lit_suppressions on public.suppressions for select to authenticated using ((select private.est_admin()));
grant select on public.suppressions to authenticated;

create or replace function public.supprimer_paiement(p_id bigint, p_motif text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pay public.paiements;
  cmd public.commandes;
  ecr jsonb;
begin
  if not (select private.est_admin()) then
    raise exception 'Réservé aux administrateurs';
  end if;
  select * into pay from public.paiements where id = p_id for update;
  if not found then
    raise exception 'Encaissement % introuvable', p_id;
  end if;
  select * into cmd from public.commandes where id = pay.commande_id for update;
  if cmd.facturee_at is not null and pay.statut = 'valide' then
    raise exception 'La commande #% est déjà facturée : supprimez la commande entière ou passez une contre-passation (journal OD).', cmd.id;
  end if;
  select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) into ecr from public.ecritures e where e.paiement_id = p_id;
  insert into public.suppressions (objet, objet_id, donnees, ecritures, motif) values ('paiement', p_id, to_jsonb(pay), ecr, p_motif);
  delete from public.ecritures where paiement_id = p_id;
  delete from public.paiements where id = p_id;
  -- Statut de la commande après retrait : plus aucun acompte validé → devis ; soldée → en cours.
  update public.commandes c
     set statut = case
       when not exists (select 1 from public.paiements p where p.commande_id = c.id and p.statut = 'valide')
         then (case when c.facturee_at is null then 'devis' else 'en_cours' end)
       when c.statut = 'soldee' then 'en_cours'
       else c.statut end
   where c.id = cmd.id and c.statut <> 'annulee';
end;
$$;

create or replace function public.supprimer_commande(p_id bigint, p_motif text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cmd public.commandes;
  pay public.paiements;
  ecr jsonb;
begin
  if not (select private.est_admin()) then
    raise exception 'Réservé aux administrateurs';
  end if;
  select * into cmd from public.commandes where id = p_id for update;
  if not found then
    raise exception 'Commande % introuvable', p_id;
  end if;
  for pay in select * from public.paiements where commande_id = p_id loop
    select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) into ecr from public.ecritures e where e.paiement_id = pay.id;
    insert into public.suppressions (objet, objet_id, donnees, ecritures, motif) values ('paiement', pay.id, to_jsonb(pay), ecr, coalesce(p_motif, 'suppression de la commande #' || p_id));
  end loop;
  select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) into ecr from public.ecritures e where e.commande_id = p_id;
  insert into public.suppressions (objet, objet_id, donnees, ecritures, motif) values ('commande', p_id, to_jsonb(cmd), ecr, p_motif);
  delete from public.ecritures where commande_id = p_id or paiement_id in (select id from public.paiements where commande_id = p_id);
  delete from public.paiements where commande_id = p_id;
  delete from public.commandes where id = p_id;
end;
$$;

revoke execute on function public.supprimer_paiement(bigint, text) from public, anon;
revoke execute on function public.supprimer_commande(bigint, text) from public, anon;
grant execute on function public.supprimer_paiement(bigint, text) to authenticated;
grant execute on function public.supprimer_commande(bigint, text) to authenticated;

-- ---------- 2. Espace client : lecture de ses propres données ----------
alter table public.commandes add column if not exists site_url text;

create or replace function private.mon_client_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.clients c
   where c.email is not null and lower(c.email) = lower(coalesce((select auth.jwt() ->> 'email'), ''))
   order by c.id limit 1;
$$;
revoke execute on function private.mon_client_id() from public, anon;
grant execute on function private.mon_client_id() to authenticated;

drop policy if exists client_lit_son_compte on public.clients;
create policy client_lit_son_compte on public.clients for select to authenticated
  using (id = (select private.mon_client_id()));
drop policy if exists client_lit_ses_commandes on public.commandes;
create policy client_lit_ses_commandes on public.commandes for select to authenticated
  using (client_id = (select private.mon_client_id()));
drop policy if exists client_lit_ses_paiements on public.paiements;
create policy client_lit_ses_paiements on public.paiements for select to authenticated
  using (commande_id in (select c.id from public.commandes c where c.client_id = (select private.mon_client_id())));

-- Un client peut lire la mention TVA de ses commandes (fonction déjà créée en 0003).
grant execute on function public.mention_tva(bigint) to authenticated;
