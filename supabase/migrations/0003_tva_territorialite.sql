-- =====================================================================
-- 0003 · TVA : assujettissement, territorialité et taux zéro à l'export
-- Règles (CGI Cameroun, LF 2020 sur le commerce électronique) :
--   * Nkapweb non assujetti (impôt libératoire)  → aucune TVA facturée (parametres.tva_applicable = false)
--   * Assujetti + client situé au Cameroun        → TVA 19,25 % (17,5 % + CAC), régime « normal »
--   * Assujetti + client situé hors du Cameroun   → exportation de services, taux zéro, régime « export »
--   * Opération exonérée par un texte             → régime « exonere », TVA nulle
-- Le régime se déduit du pays du client et peut être forcé commande par commande.
-- =====================================================================

alter table public.commandes
  add column if not exists regime_tva text check (regime_tva in ('normal', 'export', 'exonere'));

create or replace function private.calc_tva(p_ht numeric, p_regime text)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
    when p.tva_applicable and p_regime = 'normal' then round(p_ht * p.tva_taux / 100, 2)
    else 0::numeric end
  from public.parametres p where p.id = 1;
$$;
revoke execute on function private.calc_tva(numeric, text) from public, anon;
grant execute on function private.calc_tva(numeric, text) to authenticated;

create or replace function private.regime_tva_client(p_client_id bigint)
returns text
language sql
stable
set search_path = ''
as $$
  select case when lower(coalesce(c.pays, 'Cameroun')) in ('cameroun', 'cameroon', 'cm') then 'normal' else 'export' end
  from public.clients c where c.id = p_client_id;
$$;

-- À la création ou à la modification d'une commande : régime déduit du pays si non forcé, TVA recalculée.
create or replace function private.trg_commande_tva()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.regime_tva is null then
    new.regime_tva := coalesce(private.regime_tva_client(new.client_id), 'normal');
  end if;
  if new.facturee_at is null then            -- une commande facturée ne se recalcule plus
    new.tva := private.calc_tva(new.montant_ht, new.regime_tva);
  end if;
  return new;
end;
$$;
drop trigger if exists commandes_tva on public.commandes;
create trigger commandes_tva
  before insert or update of montant_ht, regime_tva, client_id on public.commandes
  for each row execute function private.trg_commande_tva();

-- Commandes existantes non facturées : régime et TVA mis à jour
update public.commandes set regime_tva = null where facturee_at is null;

-- Comptabilisation des paiements : la TVA sur abonnements / formations / autres suit la même règle
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
  regime text;
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

  insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
  values (pay.valide_at::date, 'BQ', piece, lib, tres, pay.montant_net, 0, pay.id, cmd.id);
  if pay.frais > 0 then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, 'Commission ' || pay.canal || ' · ' || piece, prm.compte_frais, pay.frais, 0, pay.id, cmd.id);
  end if;

  if pay.type = 'acompte' then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, lib, prm.compte_acompte, 0, pay.montant_brut, pay.id, cmd.id);
    update public.commandes set statut = 'acompte_recu' where id = cmd.id and statut = 'devis';

  elsif pay.type = 'solde' then
    insert into public.ecritures (date_ecriture, journal, piece, libelle, compte, debit, credit, paiement_id, commande_id)
    values (pay.valide_at::date, 'BQ', piece, lib, prm.compte_client, 0, pay.montant_brut, pay.id, cmd.id);

  else
    -- Prestation réputée rendue à l'encaissement : produit direct, TVA selon régime de la commande
    cpt_produit := case pay.type when 'abonnement' then '7062' when 'formation' then '7063' else '7068' end;
    regime := coalesce(cmd.regime_tva, private.regime_tva_client(cmd.client_id), 'normal');
    if prm.tva_applicable and regime = 'normal' then
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

-- Mention à porter sur la facture, selon le régime
create or replace function public.mention_tva(p_commande_id bigint)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when not p.tva_applicable then 'TVA non applicable (contribuable à l''impôt libératoire / non assujetti)'
    when c.regime_tva = 'export' then 'Exportation de services : TVA au taux zéro (CGI, art. 128 et suivants)'
    when c.regime_tva = 'exonere' then 'Opération exonérée de TVA'
    else 'TVA 19,25 % (17,5 % + CAC) incluse'
  end
  from public.commandes c cross join public.parametres p
  where c.id = p_commande_id and p.id = 1;
$$;
grant execute on function public.mention_tva(bigint) to authenticated;
