-- =====================================================================
-- Nkapweb · Comptabilité automatique des encaissements (SYSCOHADA révisé)
-- À exécuter dans Supabase : SQL Editor → New query → coller → Run.
-- Idempotent : peut être rejoué sans casser l'existant.
-- =====================================================================

create schema if not exists private;

-- ---------------------------------------------------------------------
-- 1. Paramètres (une seule ligne)
-- ---------------------------------------------------------------------
create table if not exists public.parametres (
  id              smallint primary key default 1 check (id = 1),
  raison_sociale  text not null default 'Nkapweb',
  devise          text not null default 'XAF',
  tva_applicable  boolean not null default false,          -- false tant que Nkapweb n'est pas assujetti (impôt libératoire)
  tva_taux        numeric(5,2) not null default 19.25,     -- 17,5 % + CAC 10 % de la TVA = 19,25 %
  compte_orange   text not null default '5381',            -- 538 Autres organismes financiers → Orange Money
  compte_mtn      text not null default '5382',            -- → MTN Mobile Money
  compte_banque   text not null default '5211',            -- 521 Banques locales
  compte_carte    text not null default '5383',            -- Agrégateur cartes (compte d'attente chez le prestataire)
  compte_especes  text not null default '5711',            -- 571 Caisse siège
  compte_frais    text not null default '6318',            -- 631 Frais bancaires → autres frais (commissions agrégateur / opérateur)
  compte_acompte  text not null default '4191',            -- 419 Clients créditeurs → avances et acomptes reçus
  compte_client   text not null default '4111',            -- 411 Clients
  compte_tva      text not null default '4431',            -- 443 État, TVA facturée
  updated_at      timestamptz not null default now()
);
insert into public.parametres (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Plan de comptes (extrait SYSCOHADA révisé utile à Nkapweb)
--    Sydney valide et complète : c'est son domaine.
-- ---------------------------------------------------------------------
create table if not exists public.comptes (
  numero   text primary key check (numero ~ '^[1-9][0-9]{0,7}$'),
  libelle  text not null,
  classe   smallint generated always as (left(numero, 1)::smallint) stored
);
insert into public.comptes (numero, libelle) values
  ('4111', 'Clients'),
  ('4191', 'Clients, avances et acomptes reçus'),
  ('4431', 'État, TVA facturée sur ventes'),
  ('5211', 'Banques locales'),
  ('5381', 'Orange Money (organisme financier)'),
  ('5382', 'MTN Mobile Money (organisme financier)'),
  ('5383', 'Agrégateur de paiement (cartes)'),
  ('5711', 'Caisse siège'),
  ('6318', 'Autres frais bancaires et commissions'),
  ('7061', 'Services vendus : création de sites'),
  ('7062', 'Services vendus : abonnements'),
  ('7063', 'Services vendus : formations'),
  ('7064', 'Services vendus : développement sur mesure'),
  ('7068', 'Autres services vendus')
on conflict (numero) do nothing;

-- ---------------------------------------------------------------------
-- 3. Clients, commandes, paiements
-- ---------------------------------------------------------------------
create table if not exists public.clients (
  id          bigint generated always as identity primary key,
  nom         text not null,
  telephone   text,
  email       text,
  ville       text,
  pays        text not null default 'Cameroun',
  created_at  timestamptz not null default now()
);

create table if not exists public.commandes (
  id            bigint generated always as identity primary key,
  client_id     bigint not null references public.clients (id) on delete restrict,
  type          text not null check (type in ('vitrine', 'boutique', 'sur_mesure', 'abonnement', 'formation', 'autre')),
  libelle       text not null,
  montant_ht    numeric(12,2) not null check (montant_ht >= 0),
  tva           numeric(12,2) not null default 0 check (tva >= 0),
  montant_ttc   numeric(12,2) generated always as (montant_ht + tva) stored,
  statut        text not null default 'devis' check (statut in ('devis', 'acompte_recu', 'en_cours', 'livree', 'soldee', 'annulee')),
  facturee_at   timestamptz,                               -- date de la facture (écriture de vente)
  created_at    timestamptz not null default now()
);
create index if not exists commandes_client_id_idx on public.commandes (client_id);
create index if not exists commandes_statut_idx on public.commandes (statut) where statut <> 'soldee';

create table if not exists public.paiements (
  id               bigint generated always as identity primary key,
  commande_id      bigint not null references public.commandes (id) on delete restrict,
  type             text not null check (type in ('acompte', 'solde', 'abonnement', 'formation', 'autre')),
  canal            text not null check (canal in ('orange_money', 'mtn_momo', 'carte', 'virement', 'especes')),
  montant_brut     numeric(12,2) not null check (montant_brut > 0),
  frais            numeric(12,2) not null default 0 check (frais >= 0 and frais < montant_brut),
  montant_net      numeric(12,2) generated always as (montant_brut - frais) stored,
  reference        text,                                   -- référence opérateur / agrégateur
  statut           text not null default 'en_attente' check (statut in ('en_attente', 'valide', 'rejete')),
  recu_at          timestamptz not null default now(),
  valide_at        timestamptz,
  comptabilise_at  timestamptz,
  note             text,
  created_at       timestamptz not null default now()
);
create index if not exists paiements_commande_id_idx on public.paiements (commande_id);
create index if not exists paiements_a_valider_idx on public.paiements (recu_at desc) where statut = 'en_attente';
create unique index if not exists paiements_reference_canal_uidx on public.paiements (canal, reference) where reference is not null;

-- ---------------------------------------------------------------------
-- 4. Journal des écritures
-- ---------------------------------------------------------------------
create table if not exists public.ecritures (
  id             bigint generated always as identity primary key,
  date_ecriture  date not null default current_date,
  journal        text not null check (journal in ('VT', 'BQ', 'OD')),   -- ventes, banque/trésorerie, opérations diverses
  piece          text not null,                                          -- ex. PAY-000012, FAC-000007
  libelle        text not null,
  compte         text not null references public.comptes (numero),
  debit          numeric(12,2) not null default 0 check (debit >= 0),
  credit         numeric(12,2) not null default 0 check (credit >= 0),
  paiement_id    bigint references public.paiements (id) on delete restrict,
  commande_id    bigint references public.commandes (id) on delete restrict,
  created_at     timestamptz not null default now(),
  constraint ecritures_un_seul_sens check ((debit = 0) <> (credit = 0))
);
create index if not exists ecritures_compte_date_idx on public.ecritures (compte, date_ecriture);
create index if not exists ecritures_piece_idx on public.ecritures (piece);
create index if not exists ecritures_paiement_id_idx on public.ecritures (paiement_id);
create index if not exists ecritures_commande_id_idx on public.ecritures (commande_id);

-- ---------------------------------------------------------------------
-- 5. Logique métier
-- ---------------------------------------------------------------------
create or replace function private.compte_tresorerie(p_canal text)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_canal
    when 'orange_money' then p.compte_orange
    when 'mtn_momo'     then p.compte_mtn
    when 'carte'        then p.compte_carte
    when 'virement'     then p.compte_banque
    else p.compte_especes end
  from public.parametres p where p.id = 1;
$$;

-- Comptabilisation d'un paiement validé (idempotente : une seule fois par paiement)
create or replace function private.comptabiliser_paiement(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  pay    public.paiements%rowtype;
  cmd    public.commandes%rowtype;
  cli    public.clients%rowtype;
  prm    public.parametres%rowtype;
  piece  text;
  lib    text;
  tres   text;
  cpt_produit text;
  ht     numeric(12,2);
  tva    numeric(12,2);
begin
  select * into pay from public.paiements where id = p_id for update;
  if not found or pay.statut <> 'valide' or pay.comptabilise_at is not null then
    return;
  end if;
  select * into cmd from public.commandes where id = pay.commande_id;
  select * into cli from public.clients where id = cmd.client_id;
  select * into prm from public.parametres where id = 1;

  if pay.valide_at is null then
    update public.paiements set valide_at = now() where id = pay.id;
    pay.valide_at := now();
  end if;
  piece := 'PAY-' || lpad(pay.id::text, 6, '0');
  tres  := private.compte_tresorerie(pay.canal);
  lib   := cli.nom || ' · ' || cmd.libelle || ' · ' || pay.type || ' (' || pay.canal || ')';

  -- Encaissement : trésorerie au net, frais en charge, le brut au crédit du compte de contrepartie
  insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
  values (pay.valide_at::date, 'BQ', piece, lib, tres, pay.montant_net, 0, pay.id, cmd.id);
  if pay.frais > 0 then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, 'Commission ' || pay.canal || ' · ' || piece, prm.compte_frais, pay.frais, 0, pay.id, cmd.id);
  end if;

  if pay.type = 'acompte' then
    -- Avance reçue avant livraison : passif client (4191), pas encore un produit
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, lib, prm.compte_acompte, 0, pay.montant_brut, pay.id, cmd.id);
    update public.commandes set statut = 'acompte_recu' where id = cmd.id and statut = 'devis';

  elsif pay.type = 'solde' then
    -- Règlement d'une facture : crédit du compte client
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, lib, prm.compte_client, 0, pay.montant_brut, pay.id, cmd.id);

  else
    -- Abonnement, formation, autre : prestation réputée rendue à l'encaissement → produit direct (+ TVA si assujetti)
    cpt_produit := case pay.type when 'abonnement' then '7062' when 'formation' then '7063' else '7068' end;
    if prm.tva_applicable then
      ht  := round(pay.montant_brut / (1 + prm.tva_taux / 100), 2);
      tva := pay.montant_brut - ht;
    else
      ht := pay.montant_brut; tva := 0;
    end if;
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'VT', piece, lib, cpt_produit, 0, ht, pay.id, cmd.id);
    if tva > 0 then
      insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
      values (pay.valide_at::date, 'VT', piece, 'TVA ' || prm.tva_taux || ' % · ' || piece, prm.compte_tva, 0, tva, pay.id, cmd.id);
    end if;
  end if;

  update public.paiements set comptabilise_at = now() where id = pay.id;
end;
$$;

-- Facturation d'une commande livrée : constate le produit, reclasse l'acompte
create or replace function public.facturer_commande(p_commande_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cmd   public.commandes%rowtype;
  cli   public.clients%rowtype;
  prm   public.parametres%rowtype;
  piece text;
  cpt_produit text;
  acomptes numeric(12,2);
begin
  if not exists (select 1 from public.admins where user_id = (select auth.uid())) then
    raise exception 'Accès refusé';
  end if;
  select * into cmd from public.commandes where id = p_commande_id for update;
  if not found or cmd.facturee_at is not null then return; end if;
  select * into cli from public.clients where id = cmd.client_id;
  select * into prm from public.parametres where id = 1;
  piece := 'FAC-' || lpad(cmd.id::text, 6, '0');
  cpt_produit := case cmd.type when 'vitrine' then '7061' when 'boutique' then '7061' when 'sur_mesure' then '7064'
                               when 'abonnement' then '7062' when 'formation' then '7063' else '7068' end;

  insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, commande_id)
  values (current_date, 'VT', piece, cli.nom || ' · ' || cmd.libelle, prm.compte_client, cmd.montant_ttc, 0, cmd.id);
  insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, commande_id)
  values (current_date, 'VT', piece, cli.nom || ' · ' || cmd.libelle, cpt_produit, 0, cmd.montant_ht, cmd.id);
  if cmd.tva > 0 then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, commande_id)
    values (current_date, 'VT', piece, 'TVA · ' || piece, prm.compte_tva, 0, cmd.tva, cmd.id);
  end if;

  -- Reclassement des acomptes déjà encaissés : 4191 → 411
  select coalesce(sum(montant_brut), 0) into acomptes
  from public.paiements where commande_id = cmd.id and type = 'acompte' and statut = 'valide';
  if acomptes > 0 then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, commande_id)
    values (current_date, 'OD', piece, 'Imputation acompte · ' || piece, prm.compte_acompte, acomptes, 0, cmd.id);
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, commande_id)
    values (current_date, 'OD', piece, 'Imputation acompte · ' || piece, prm.compte_client, 0, acomptes, cmd.id);
  end if;

  update public.commandes set facturee_at = now(), statut = case when statut in ('devis', 'acompte_recu', 'en_cours') then 'livree' else statut end
  where id = cmd.id;
end;
$$;

-- Déclencheur : dès qu'un paiement passe à « valide », il est comptabilisé
create or replace function private.trg_paiement_valide()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.statut = 'valide' and (tg_op = 'INSERT' or old.statut is distinct from 'valide') then
    if new.valide_at is null then new.valide_at := now(); end if;
  end if;
  return new;
end;
$$;
drop trigger if exists paiements_avant_validation on public.paiements;
create trigger paiements_avant_validation
  before insert or update of statut on public.paiements
  for each row execute function private.trg_paiement_valide();

create or replace function private.trg_paiement_comptabiliser()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.statut = 'valide' and new.comptabilise_at is null then
    perform private.comptabiliser_paiement(new.id);
  end if;
  return null;
end;
$$;
drop trigger if exists paiements_apres_validation on public.paiements;
create trigger paiements_apres_validation
  after insert or update of statut on public.paiements
  for each row execute function private.trg_paiement_comptabiliser();

-- Solde automatique de la commande quand client (411) est à zéro après facture
create or replace function private.trg_solder_commande()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  reste numeric(12,2);
  prm   public.parametres%rowtype;
begin
  select * into prm from public.parametres where id = 1;
  if new.commande_id is not null then
    select coalesce(sum(debit) - sum(credit), 0) into reste
    from public.ecritures where commande_id = new.commande_id and compte = prm.compte_client;
    if reste = 0 and exists (select 1 from public.commandes where id = new.commande_id and facturee_at is not null) then
      update public.commandes set statut = 'soldee' where id = new.commande_id and statut <> 'annulee';
    end if;
  end if;
  return null;
end;
$$;
drop trigger if exists ecritures_apres_insert on public.ecritures;
create trigger ecritures_apres_insert
  after insert on public.ecritures
  for each row execute function private.trg_solder_commande();

-- ---------------------------------------------------------------------
-- 6. Vues de restitution
-- ---------------------------------------------------------------------
create or replace view public.v_journal with (security_invoker = true) as
  select e.id, e.date_ecriture, e.journal, e.piece, e.compte, c.libelle as compte_libelle, e.libelle, e.debit, e.credit, e.paiement_id, e.commande_id
  from public.ecritures e join public.comptes c on c.numero = e.compte
  order by e.date_ecriture, e.piece, e.id;

create or replace view public.v_balance with (security_invoker = true) as
  select c.numero as compte, c.libelle, c.classe,
         coalesce(sum(e.debit), 0)::numeric(14,2)  as total_debit,
         coalesce(sum(e.credit), 0)::numeric(14,2) as total_credit,
         (coalesce(sum(e.debit), 0) - coalesce(sum(e.credit), 0))::numeric(14,2) as solde
  from public.comptes c left join public.ecritures e on e.compte = c.numero
  group by c.numero, c.libelle, c.classe
  order by c.numero;

create or replace view public.v_encaissements_mois with (security_invoker = true) as
  select date_trunc('month', valide_at)::date as mois, canal,
         count(*) as nb, sum(montant_brut)::numeric(14,2) as brut, sum(frais)::numeric(14,2) as frais, sum(montant_net)::numeric(14,2) as net
  from public.paiements where statut = 'valide'
  group by 1, 2 order by 1 desc, 2;

-- ---------------------------------------------------------------------
-- 7. Sécurité : seul(s) les administrateurs déclarés accèdent aux données
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function private.est_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = (select auth.uid()));
$$;
revoke execute on function private.est_admin() from public, anon;
grant execute on function private.est_admin() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['parametres', 'comptes', 'clients', 'commandes', 'paiements', 'ecritures', 'admins'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists admin_tout on public.%I', t);
    execute format('create policy admin_tout on public.%I for all to authenticated using ((select private.est_admin())) with check ((select private.est_admin()))', t);
  end loop;
end $$;

-- Les écritures ne se modifient ni ne s'effacent depuis l'application : on contre-passe.
drop policy if exists admin_tout on public.ecritures;
create policy ecritures_lecture on public.ecritures for select to authenticated using ((select private.est_admin()));
create policy ecritures_insert_od on public.ecritures for insert to authenticated with check ((select private.est_admin()) and journal = 'OD');

grant usage on schema public to anon, authenticated;
grant select, insert, update on public.clients, public.commandes, public.paiements, public.parametres to authenticated;
grant select on public.comptes, public.ecritures, public.admins, public.v_journal, public.v_balance, public.v_encaissements_mois to authenticated;
grant insert on public.ecritures to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.facturer_commande(bigint) to authenticated;
grant usage on schema private to authenticated;
revoke all on schema private from anon;
revoke execute on function private.comptabiliser_paiement(bigint) from public, anon, authenticated;
revoke execute on function private.compte_tresorerie(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Après exécution : déclarer Sydney administrateur
--    (remplacer l'e-mail par celui utilisé pour se connecter à /admin)
-- ---------------------------------------------------------------------
-- insert into public.admins (user_id)
--   select id from auth.users where email = 'bonjour@nkapweb.com'
-- on conflict do nothing;
