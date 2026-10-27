-- Correctif 0002 : date de validation renseignée aussi quand un paiement est créé directement « validé ».
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

-- Ceinture et bretelles : la comptabilisation pose la date si elle manque encore.
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

