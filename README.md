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
- `api/assistant.js` : assistant IA du configurateur (`/creer`). Reçoit la conversation et l'état du site, renvoie une réponse et un patch (textes, style, palette, sections, produits) appliqué à l'aperçu. Utilise le SDK officiel `@anthropic-ai/sdk` avec sortie structurée JSON et repli serveur (`fallbacks: "default"`).
  Variables d'environnement : `ANTHROPIC_API_KEY` (clé créée sur https://platform.claude.com, menu API keys), facultatif `ANTHROPIC_MODEL` (par défaut `claude-opus-5-5` ; `claude-sonnet-5-5` ou `claude-haiku-5-5` pour réduire le coût).
  L'assistant est inclus dans le pack (20 échanges par site, plafond `IA_MAX` dans `creer/index.html`) : le coût API réel (environ 30 FCFA par échange) reste inscrit dans le brief pour suivre la marge. Chaque réponse serveur renvoie le coût API réel (jetons × tarif, converti en FCFA par règle de trois : cours de référence BCE EUR/USD du jour, lu sur le flux public de la BCE et mis en cache 12 h, et parité fixe 1 EUR = 655,957 XAF ; `TAUX_USD_XAF` ne sert que de repli si la BCE est injoignable) ; le brief reçu par e-mail indique le nombre d'échanges, le montant facturé et ce coût pour suivre la marge. `ASSISTANT_MAX` (20) borne le nombre d'échanges acceptés par conversation. Les montants côté page sont dans `creer/index.html` (`IA_PRIX`, `IA_OFFERTS`, `IA_MAX`). Sans clé, la page bascule sur un assistant local par mots-clés (activité, ville, style, couleurs) et le configurateur reste entièrement utilisable.

## Comptabilité automatique (Supabase)
1. Créer un projet Supabase, ouvrir SQL Editor, exécuter dans l'ordre `supabase/migrations/0001_compta_nkapweb.sql`, `0002_correctif_date_validation.sql`, `0003_tva_territorialite.sql`.
2. Dans Authentication → Users, inviter l'adresse qui servira à se connecter à `/admin` (ou se connecter une première fois par lien magique).
3. Déclarer cet utilisateur administrateur :
   `insert into public.admins (user_id) select id from auth.users where email = 'bonjour@nkapweb.com';`
4. L'URL du projet et la clé anon sont inscrites en tête du script de `admin/index.html` (Project Settings → API).
5. Dans `/admin`, enregistrer un encaissement et le valider : les écritures (trésorerie au net, commission, acompte / client / produit, TVA si assujetti) sont générées par la base.

## Déploiement
Chaque poussée sur `main` redéploie www.nkapweb.com (projet Vercel `nkapweb-site-`).

## Version anglaise

- `en/index.html`, `en/training/`, `en/custom/` : traductions des pages de vente, formations et sur-mesure. Chaque page porte `<html lang>`, un lien canonique et les balises hreflang fr / en / x-default ; le sitemap les reprend. Un sélecteur FR / EN figure dans chaque en-tête.
- `en/create/index.html` est une **copie exacte** de `creer/index.html` : le configurateur détecte la langue d'après le chemin (`/en/`) ou `?lang=en`, traduit l'interface, les contenus préremplis, l'aperçu généré et l'assistant, et envoie `lang` aux fonctions serveur (accusé de réception en anglais, assistant qui répond en anglais). Après toute modification de `creer/index.html`, resynchroniser : `cp creer/index.html en/create/index.html`.
- Les démos `demo/vitrine/` et `demo/boutique/` restent en français (exemples de sites clients) ; le brief reçu par e-mail reste en français et indique la langue du client.

## Blog et positionnement

- `blog/` : articles de fond (prix, délais, conseils) destinés au référencement, sur le modèle des guides que publient les agences concurrentes. Premier article : `blog/prix-site-web-cameroun-2026/`. Les articles restent en français pour l'instant.
- Pack « Page unique » (120 000 FCFA ou 8 000 FCFA par mois, 3 jours ouvrés) : offre d'entrée ajoutée après le benchmark des agences (Elimboo, Dakar.dev, Digit Communication). Présente sur la page de vente et dans le configurateur (`?pack=page`), sections limitées à services et horaires.
- Le benchmark détaillé est dans le skill Nkapweb, fichier `references/concurrence.md`.

## Espace client, suppressions et commande

- `client/` : espace client (connexion par lien e-mail Supabase, lecture de ses commandes, paiements, facture, adresse du site livré, liens formations et WhatsApp). Le client est reconnu par l'e-mail saisi dans l'espace de gestion (champ « E-mail » à la création du client). Migration `supabase/migrations/0004_suppressions_et_espace_client.sql` à exécuter.
- Espace de gestion : boutons « Supprimer » sur les encaissements et les commandes (fonctions `supprimer_paiement` et `supprimer_commande`, copie conservée dans la table `suppressions`) ; bouton « Site » pour renseigner l'adresse du site livré. Un encaissement validé d'une commande déjà facturée ne se supprime pas seul : supprimer la commande entière ou contre-passer.
- À la commande dans le configurateur, l'e-mail reçu contient le brief, le logo, la photo d'accueil, les photos de produits (pack Boutique) et de galerie, et le fichier `site-propose.html` : le site généré, prêt à déployer tel quel. La mise en ligne automatique (dépôt GitHub et projet Vercel créés par API) est la prochaine étape, après l'agrégateur de paiement.

