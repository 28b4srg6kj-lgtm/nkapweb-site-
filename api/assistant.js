// Assistant IA du configurateur : reçoit la conversation et l'état du site en cours,
// renvoie une réponse courte en français et un « patch » (champs à modifier) que la
// page /creer applique immédiatement à l'aperçu.
// Variables d'environnement Vercel : ANTHROPIC_API_KEY (obligatoire),
// ANTHROPIC_MODEL (facultatif, par défaut claude-opus-5-5), ASSISTANT_MAX (échanges par
// conversation, 20). Le coût API est converti en FCFA avec le cours de référence BCE EUR/USD du
// jour et la parité fixe 1 EUR = 655,957 XAF (règle de trois) ; TAUX_USD_XAF sert de repli.
// Chaque réponse renvoie le coût réel de l'appel (jetons × tarif) pour le suivi de marge.
const Anthropic = require('@anthropic-ai/sdk');

const MODELE = process.env.ANTHROPIC_MODEL || 'claude-opus-5-5';
// Quota d'échanges par conversation (le forfait facturé au client couvre ce nombre)
const MAX_ECHANGES = Number(process.env.ASSISTANT_MAX) || 20;
// Tarifs API en dollars par million de jetons : entrée, sortie, lecture de cache, écriture de cache
const TARIFS = {
  'claude-opus-5-5': [4, 20, 0.2, 5],
  'claude-sonnet-5-5': [2, 10, 0.2, 2.5],
  'claude-haiku-5-5': [0.1, 0.5, 0.01, 0.125]
};
// Conversion USD → XAF : 1 EUR = 655,957 XAF (parité fixe), EUR/USD = cours de référence BCE du jour.
const EUR_XAF = 655.957;
const TAUX_REPLI = Number(process.env.TAUX_USD_XAF) || 600;
const BCE_URL = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml';
let cacheBce = { date: '', eurUsd: 0, lu: 0 };

function lireBce(xml) {
  const d = /time=['"](\d{4}-\d{2}-\d{2})['"]/.exec(xml);
  const u = /currency=['"]USD['"]\s+rate=['"]([\d.]+)['"]/.exec(xml);
  if (!u) return null;
  const eurUsd = Number(u[1]);
  if (!(eurUsd > 0.5 && eurUsd < 2)) return null;
  return { date: d ? d[1] : '', eurUsd };
}

// Taux USD → XAF du jour, mis en cache 12 h dans l'instance. Repli : TAUX_USD_XAF.
async function tauxUsdXaf() {
  if (cacheBce.eurUsd && Date.now() - cacheBce.lu < 12 * 3600 * 1000) {
    return { taux: Math.round(EUR_XAF / cacheBce.eurUsd * 100) / 100, source: 'BCE ' + cacheBce.date, eurUsd: cacheBce.eurUsd };
  }
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 4000);
    const r = await fetch(BCE_URL, { signal: ctrl.signal, headers: { 'User-Agent': 'nkapweb-assistant/1.0' } });
    clearTimeout(t);
    const bce = r.ok ? lireBce(await r.text()) : null;
    if (bce) {
      cacheBce = { date: bce.date, eurUsd: bce.eurUsd, lu: Date.now() };
      return { taux: Math.round(EUR_XAF / bce.eurUsd * 100) / 100, source: 'BCE ' + bce.date, eurUsd: bce.eurUsd };
    }
  } catch (e) {
    console.error('Cours BCE indisponible :', e && e.message);
  }
  if (cacheBce.eurUsd) return { taux: Math.round(EUR_XAF / cacheBce.eurUsd * 100) / 100, source: 'BCE ' + cacheBce.date + ' (cache)', eurUsd: cacheBce.eurUsd };
  return { taux: TAUX_REPLI, source: 'repli', eurUsd: 0 };
}

function cout(usage, modele, change) {
  const t = TARIFS[modele] || TARIFS['claude-opus-5-5'];
  const u = usage || {};
  const usd = ((u.input_tokens || 0) * t[0] + (u.output_tokens || 0) * t[1] + (u.cache_read_input_tokens || 0) * t[2] + (u.cache_creation_input_tokens || 0) * t[3]) / 1e6;
  return { usd: Math.round(usd * 10000) / 10000, fcfa: Math.round(usd * change.taux), taux: change.taux, source: change.source, entree: (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0), sortie: u.output_tokens || 0 };
}

const TYPES = ['pharmacie', 'restaurant', 'cabinet', 'ecole', 'salon', 'boutique', 'immobilier', 'btp', 'hotel', 'ong', 'autre'];
const STYLES = ['epure', 'classique', 'editorial', 'audacieux', 'chaleureux', 'minimal', 'vibrant', 'nature'];
const PALS = ['vert', 'bleu', 'terre', 'nuit', 'corail', 'violet', 'ocean', 'or', 'perso'];

const SCHEMA = {
  type: 'object',
  properties: {
    reponse: { type: 'string', description: 'Réponse au client en français, 2 à 4 phrases, ton chaleureux et concret. Dire ce qui a été appliqué.' },
    patch: {
      type: 'object',
      description: 'Uniquement les champs à modifier. Laisser vides ceux qui ne changent pas.',
      properties: {
        pack: { type: 'string', enum: ['vitrine', 'boutique', ''] },
        type: { type: 'string', enum: TYPES.concat(['']) },
        nom: { type: 'string' },
        ville: { type: 'string' },
        quartier: { type: 'string' },
        slogan: { type: 'string', description: 'Accroche de 4 à 10 mots, sans point d’exclamation.' },
        intro: { type: 'string', description: 'Texte de présentation, 2 phrases, 160 caractères maximum.' },
        cta: { type: 'string', description: 'Libellé du bouton principal, 2 à 4 mots.' },
        services: { type: 'array', items: { type: 'string' }, description: 'Exactement 3 services ou 0.' },
        produits: { type: 'array', items: { type: 'array', items: { type: ['string', 'number'] } }, description: 'Jusqu’à 6 couples [nom, prix en FCFA].' },
        style: { type: 'string', enum: STYLES.concat(['']) },
        pal: { type: 'string', enum: PALS.concat(['']) },
        couleur: { type: 'string', description: 'Couleur principale hexadécimale #rrggbb si pal = perso, sinon vide.' },
        hero: { type: 'string', enum: ['split', 'centre', 'photo', ''] },
        coins: { type: 'string', enum: ['arrondi', 'doux', 'carre', ''] },
        boutons: { type: 'string', enum: ['pilule', 'droit', ''] },
        entete: { type: 'string', enum: ['clair', 'fonce', ''] },
        sections: {
          type: 'object',
          properties: { services: { type: 'boolean' }, horaires: { type: 'boolean' }, equipe: { type: 'boolean' }, avis: { type: 'boolean' }, galerie: { type: 'boolean' }, faq: { type: 'boolean' } },
          required: ['services', 'horaires', 'equipe', 'avis', 'galerie', 'faq'],
          additionalProperties: false
        },
        horaires: { type: 'string' },
        adresse: { type: 'string' },
        livraison: { type: 'string' }
      },
      required: ['pack', 'type', 'nom', 'ville', 'quartier', 'slogan', 'intro', 'cta', 'services', 'produits', 'style', 'pal', 'couleur', 'hero', 'coins', 'boutons', 'entete', 'horaires', 'adresse', 'livraison'],
      additionalProperties: false
    }
  },
  required: ['reponse', 'patch'],
  additionalProperties: false
};

const SYSTEME = [
  'Tu es l’assistant de création de Nkapweb (www.nkapweb.com), une agence camerounaise qui vend des sites internet payables par Orange Money, MTN Mobile Money et carte bancaire, en Afrique centrale, en Afrique de l’Ouest et en Europe.',
  'Tu aides un commerçant ou un professionnel à composer son site dans le configurateur. À chaque message, tu réponds en français simple, en 2 à 4 phrases, puis tu renvoies un patch avec seulement les champs à changer.',
  '',
  'Ce que tu peux modifier :',
  '- pack : vitrine (présenter, être contacté) ou boutique (vendre en ligne, panier, paiement mobile money).',
  '- type d’activité : ' + TYPES.join(', ') + '.',
  '- textes : nom, ville, quartier, slogan, intro, cta, services (exactement 3), produits (jusqu’à 6 couples [nom, prix FCFA], utiles surtout en pack boutique), horaires, adresse, livraison.',
  '- style : epure (moderne, sobre), classique (serif élégant), editorial (grands titres serif, lignes fines), audacieux (titres massifs, en-tête sombre), chaleureux (serif doux, tons chauds), minimal (très épuré, gris, angles vifs), vibrant (couleurs franches, formes rondes), nature (serif, verts profonds, photo en pleine largeur).',
  '- palette : vert, bleu, terre, nuit, corail, violet, ocean, or, ou perso avec une couleur hexadécimale.',
  '- mise en page : hero split (texte + encart), centre (titre centré), photo (photo en fond) ; coins arrondi, doux ou carre ; boutons pilule ou droit ; entete clair ou fonce.',
  '- sections : services, horaires, equipe, avis, galerie, faq (booléens).',
  '',
  'Règles :',
  '- Écris des textes crédibles, concrets et locaux (villes et quartiers réels du pays du client, FCFA, WhatsApp). Pas de superlatifs creux, pas de point d’exclamation.',
  '- N’invente jamais de témoignages, de chiffres de clients ni de certifications. Si le client veut des avis, active la section avis : ils seront remplacés par de vrais avis.',
  '- Choisis un style et une palette cohérents avec le métier (pharmacie : vert ou ocean, epure ; restaurant : chaleureux ou vibrant, terre ou corail ; cabinet d’avocats : classique ou editorial, nuit ou bleu ; école : epure, bleu ; salon de beauté : chaleureux ou vibrant, violet ou corail ; hôtel : nature ou editorial ; BTP ou immobilier : audacieux ou minimal ; ONG : nature ou epure).',
  '- Si le client décrit une activité qui vend des produits ou des plats à livrer, propose le pack boutique et remplis 6 produits avec des prix plausibles en FCFA.',
  '- Si le client demande seulement un avis ou une question de prix, réponds sans rien modifier (patch vide : chaînes vides, tableaux vides, et ne touche pas aux sections sauf demande).',
  '- Tarifs Nkapweb : Vitrine 250 000 FCFA ou 15 000 FCFA par mois ; Boutique 600 000 FCFA ou 30 000 FCFA par mois ; sur-mesure à partir de 1 200 000 FCFA ; acompte 50 % ; options : logo 40 000, rédaction 50 000, photos 60 000, version anglaise 60 000, maintenance 10 000 par mois.',
  '- Ne modifie pas le nom de l’entreprise si le client ne le donne pas. Pour les sections, renvoie toujours les 6 booléens en gardant les valeurs actuelles sauf changement voulu.',
  '- Si le message n’a rien à voir avec la création du site, ramène poliment vers le site en une phrase.'
].join('\n');

function texte(v, max) {
  return String(v == null ? '' : v).replace(/\s+/g, ' ').trim().slice(0, max);
}

function nettoieEtat(e) {
  if (!e || typeof e !== 'object') return {};
  const out = {};
  ['pack', 'type', 'nom', 'ville', 'quartier', 'slogan', 'intro', 'cta', 'style', 'pal', 'couleur', 'hero', 'coins', 'boutons', 'entete', 'horaires', 'adresse', 'livraison', 'pays'].forEach(function (k) {
    if (e[k] != null) out[k] = texte(e[k], 200);
  });
  if (Array.isArray(e.services)) out.services = e.services.slice(0, 3).map(function (s) { return texte(s, 60); });
  if (Array.isArray(e.produits)) out.produits = e.produits.slice(0, 6).map(function (p) { return [texte(p && p[0], 60), Number(p && p[1]) || 0]; });
  if (e.sections && typeof e.sections === 'object') {
    out.sections = {};
    ['services', 'horaires', 'equipe', 'avis', 'galerie', 'faq'].forEach(function (k) { out.sections[k] = !!e.sections[k]; });
  }
  return out;
}

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'Méthode non autorisée.' });

  let body = req.body || {};
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }

  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(503).json({ ok: false, code: 'no_key', error: 'Assistant non configuré.' });
  }

  const nb = Number(body.nb) || 0;
  if (nb > MAX_ECHANGES) {
    return res.status(429).json({ ok: false, code: 'quota', error: 'Forfait de ' + MAX_ECHANGES + ' échanges atteint.' });
  }
  const historique = Array.isArray(body.messages) ? body.messages.slice(-12) : [];
  const messages = [];
  historique.forEach(function (m) {
    const role = m && m.role === 'assistant' ? 'assistant' : 'user';
    const content = texte(m && m.content, 1500);
    if (!content) return;
    if (messages.length && messages[messages.length - 1].role === role) {
      messages[messages.length - 1].content += '\n' + content;
    } else {
      messages.push({ role, content });
    }
  });
  if (!messages.length || messages[messages.length - 1].role !== 'user') {
    return res.status(400).json({ ok: false, error: 'Message manquant.' });
  }
  const etat = nettoieEtat(body.etat);
  const lang = body.lang === 'en' ? 'en' : 'fr';
  messages[messages.length - 1].content += '\n\n[État actuel du configurateur, en JSON]\n' + JSON.stringify(etat) + (lang === 'en' ? '\n\n[Le client utilise l’interface en anglais : réponds en anglais et rédige tous les textes du patch (slogan, intro, cta, services, produits, horaires, adresse, livraison) en anglais.]' : '');

  const client = new Anthropic({ timeout: 40000, maxRetries: 1 });
  try {
    const r = await client.beta.messages.create({
      model: MODELE,
      max_tokens: 2500,
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      system: [{ type: 'text', text: SYSTEME, cache_control: { type: 'ephemeral' } }],
      messages,
      output_config: { effort: 'low', format: { type: 'json_schema', schema: SCHEMA } }
    });
    const c = cout(r.usage, r.model || MODELE, await tauxUsdXaf());
    if (r.stop_reason === 'refusal') {
      return res.status(200).json({ ok: true, reponse: 'Je ne peux pas aider sur ce point. Décrivez-moi plutôt votre activité et vos clients, je m’occupe des textes et du style.', patch: {}, cout: c });
    }
    const bloc = (r.content || []).filter(function (b) { return b.type === 'text'; }).map(function (b) { return b.text; }).join('');
    let sortie;
    try { sortie = JSON.parse(bloc); } catch (e) { sortie = null; }
    if (!sortie || typeof sortie.reponse !== 'string') {
      return res.status(502).json({ ok: false, error: 'Réponse inexploitable.' });
    }
    const patch = sortie.patch && typeof sortie.patch === 'object' ? sortie.patch : {};
    Object.keys(patch).forEach(function (k) {
      const v = patch[k];
      if (v === '' || v == null || (Array.isArray(v) && !v.length)) delete patch[k];
    });
    if (patch.couleur && !/^#[0-9a-fA-F]{6}$/.test(patch.couleur)) delete patch.couleur;
    return res.status(200).json({ ok: true, reponse: texte(sortie.reponse, 900), patch, modele: r.model || MODELE, cout: c });
  } catch (e) {
    console.error('Assistant :', e && e.status, e && e.message);
    const status = e && e.status === 429 ? 429 : 502;
    return res.status(status).json({ ok: false, error: status === 429 ? 'Assistant très sollicité, réessayez dans une minute.' : 'L’assistant n’a pas répondu.' });
  }
};
module.exports.lireBce = lireBce;
module.exports.tauxUsdXaf = tauxUsdXaf;
