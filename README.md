# Nkapweb — site de vente, configurateur et gestion

Agence Nkapweb : sites internet payables par Orange Money, MTN Mobile Money, carte GIMAC et carte bancaire.

## Pages
- `index.html` — page de vente (packs, livrables, formations, abonnement, FAQ, formulaire de devis)
- `creer/` — configurateur : le client compose son site Vitrine ou Boutique (logo, couleurs, sections, produits), aperçu en direct, commande
- `formations/` — programme détaillé des trois séries de formation
- `sur-mesure/` — parcours en six étapes et questionnaire de cadrage pour les applications sur-mesure
- `demo/vitrine/`, `demo/boutique/` — sites de démonstration
- `admin/` — espace de gestion Nkapweb (encaissements, commandes, journal, balance SYSCOHADA), branché sur Supabase

## Fonctions serveur (Vercel)
- `api/devis.js` — reçoit les formulaires et envoie un e-mail via la boîte OVH (pièce jointe logo possible).
  Variables d'environnement : `SMTP_USER`, `SMTP_PASS` (facultatif `SMTP_HOST`, `DEVIS_TO`).

## Comptabilité automatique (Supabase)
1. Créer un projet Supabase, ouvrir SQL Editor, exécuter dans l'ordre `supabase/migrations/0001_compta_nkapweb.sql`, `0002_correctif_date_validation.sql`, `0003_tva_territorialite.sql`.
2. Dans Authentication → Users, inviter l'adresse qui servira à se connecter à `/admin` (ou se connecter une première fois par lien magique).
3. Déclarer cet utilisateur administrateur :
   `insert into public.admins (user_id) select id from auth.users where email = 'bonjour@nkapweb.com';`
4. L'URL du projet et la clé anon sont inscrites en tête du script de `admin/index.html` (Project Settings → API).
5. Dans `/admin`, enregistrer un encaissement et le valider : les écritures (trésorerie au net, commission, acompte / client / produit, TVA si assujetti) sont générées par la base.

## Déploiement
Chaque poussée sur `main` redéploie www.nkapweb.com (projet Vercel `nkapweb-site-`).
