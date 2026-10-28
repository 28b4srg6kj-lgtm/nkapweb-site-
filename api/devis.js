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
  const lang = body.lang === 'en' ? 'en' : 'fr';
  const logo = typeof body.logo === 'string' ? body.logo : '';
  const attachments = [];
  if (logo) {
    const m = logo.match(/^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)$/);
    if (!m || m[2].length > 600000) {
      return res.status(400).json({ ok: false, error: 'Logo invalide ou trop lourd (400 Ko maximum).' });
    }
    attachments.push({ filename: 'logo.' + (m[1] === 'jpeg' ? 'jpg' : m[1]), content: m[2], encoding: 'base64' });
  }
  const photo = typeof body.photo === 'string' ? body.photo : '';
  if (photo) {
    const m = photo.match(/^data:image\/(jpeg|webp);base64,([A-Za-z0-9+/=]+)$/);
    if (!m || m[2].length > 900000) {
      return res.status(400).json({ ok: false, error: 'Photo invalide ou trop lourde.' });
    }
    attachments.push({ filename: 'photo-accueil.' + (m[1] === 'jpeg' ? 'jpg' : m[1]), content: m[2], encoding: 'base64' });
  }
  // Photos de produits et de galerie déposées dans le configurateur (12 au plus).
  const photos = Array.isArray(body.photos) ? body.photos.slice(0, 12) : [];
  for (const ph of photos) {
    const data = ph && typeof ph.data === 'string' ? ph.data : '';
    const mp = data.match(/^data:image\/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)$/);
    if (!mp || mp[2].length > 600000) continue;
    const nomPhoto = String(ph.nom || 'photo').replace(/[^a-z0-9_-]/gi, '').slice(0, 40) || 'photo';
    attachments.push({ filename: nomPhoto + '.' + (mp[1] === 'jpeg' ? 'jpg' : mp[1]), content: mp[2], encoding: 'base64' });
  }
  // Site généré par le configurateur, joint tel quel : il se déploie sans retouche.
  const siteHtml = typeof body.site_html === 'string' ? body.site_html : '';
  if (siteHtml && siteHtml.length <= 3500000 && /^<!doctype html>/i.test(siteHtml.trim())) {
    attachments.push({ filename: 'site-propose.html', content: siteHtml, contentType: 'text/html; charset=utf-8' });
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
    'Langue    : ' + (lang === 'en' ? 'anglais' : 'français'),
    'Détails   : ' + (message || 'aucun'),
    'Fichiers  : ' + (attachments.length ? attachments.map(function (a) { return a.filename; }).join(', ') + ' (joints)' : 'aucun'),
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
        subject: lang === 'en' ? 'Your Nkapweb quote request has been received' : 'Votre demande de devis Nkapweb est bien reçue',
        text: lang === 'en' ? [
          'Hello ' + nom + ',',
          '',
          'Thank you for your request (' + pack + ', ' + pays + '). We will get back to you within 24 hours,',
          'on WhatsApp at ' + tel + ' or by e-mail.',
          '',
          'To move faster, write to us directly: https://wa.me/237696745707',
          '',
          'Nkapweb · Websites paid with Orange Money, MTN Mobile Money and bank card',
          'bonjour@nkapweb.com · www.nkapweb.com/en/',
        ].join('\n') : [
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
