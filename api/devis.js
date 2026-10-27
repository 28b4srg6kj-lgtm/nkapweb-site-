// Réception du formulaire de devis : envoi par e-mail via la boîte OVH (SMTP),
// accusé de réception au client s'il a laissé une adresse.
// Variables d'environnement à définir dans Vercel : SMTP_USER, SMTP_PASS
// (facultatif : SMTP_HOST, DEVIS_TO).
const nodemailer = require('nodemailer');

function champ(v, max) {
  return String(v == null ? '' : v).trim().slice(0, max);
}

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'Méthode non autorisée.' });
  }

  let body = req.body || {};
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch (e) { body = {}; }
  }

  // Piège à robots : champ invisible qui doit rester vide.
  if (champ(body.site, 10)) return res.status(200).json({ ok: true });

  const nom = champ(body.nom, 80);
  const tel = champ(body.tel, 30);
  const email = champ(body.email, 120);
  const pays = champ(body.pays, 40);
  const pack = champ(body.pack, 40);
  const message = champ(body.message, 6000);
  const logo = typeof body.logo === 'string' ? body.logo : '';
  const attachments = [];
  if (logo) {
    const m = logo.match(/^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)$/);
    if (!m || m[2].length > 600000) {
      return res.status(400).json({ ok: false, error: 'Logo invalide ou trop lourd (400 Ko maximum).' });
    }
    attachments.push({ filename: 'logo.' + (m[1] === 'jpeg' ? 'jpg' : m[1]), content: m[2], encoding: 'base64' });
  }

  if (!nom || tel.replace(/\D/g, '').length < 8) {
    return res.status(400).json({ ok: false, error: 'Nom et numéro WhatsApp requis.' });
  }
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ ok: false, error: 'Adresse e-mail invalide.' });
  }

  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;
  if (!user || !pass) {
    return res.status(503).json({ ok: false, error: 'Envoi e-mail non configuré.' });
  }

  const transport = nodemailer.createTransport({
    host: process.env.SMTP_HOST || 'smtp.mail.ovh.net',
    port: 465,
    secure: true,
    auth: { user, pass },
  });

  const dest = process.env.DEVIS_TO || user;
  const quand = new Date().toLocaleString('fr-FR', { timeZone: 'Africa/Douala' });
  const texte = [
    'Nouvelle demande de devis depuis www.nkapweb.com',
    '',
    'Nom       : ' + nom,
    'WhatsApp  : ' + tel,
    'E-mail    : ' + (email || 'non renseigné'),
    'Pays      : ' + pays,
    'Besoin    : ' + pack,
    'Détails   : ' + (message || 'aucun'),
    'Logo      : ' + (attachments.length ? 'joint à ce message' : 'non fourni'),
    '',
    'Reçue le ' + quand + ' (heure du Cameroun).',
    'Répondre sur WhatsApp : https://wa.me/' + tel.replace(/\D/g, ''),
  ].join('\n');

  try {
    await transport.sendMail({
      from: '"Nkapweb · Formulaire" <' + user + '>',
      to: dest,
      replyTo: email || undefined,
      subject: 'Demande de devis · ' + pack + ' · ' + nom,
      text: texte,
      attachments: attachments,
    });
    if (email) {
      await transport.sendMail({
        from: '"Nkapweb" <' + user + '>',
        to: email,
        subject: 'Votre demande de devis Nkapweb est bien reçue',
        text: [
          'Bonjour ' + nom + ',',
          '',
          'Merci pour votre demande (' + pack + ', ' + pays + '). Nous revenons vers vous sous 24 h,',
          'par WhatsApp au ' + tel + ' ou par e-mail.',
          '',
          'Pour aller plus vite, écrivez-nous directement : https://wa.me/237696745707',
          '',
          'Nkapweb · Sites internet payables par Orange Money, MTN Mobile Money et carte bancaire',
          'bonjour@nkapweb.com · www.nkapweb.com',
        ].join('\n'),
      });
    }
    return res.status(200).json({ ok: true });
  } catch (e) {
    console.error('Envoi devis échoué :', e && e.message);
    return res.status(502).json({ ok: false, error: "L'e-mail n'a pas pu être envoyé." });
  }
};
