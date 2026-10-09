/**
 * Altius HRMS — Google Drive bridge (Google Apps Script web app)
 *
 * Saves the HRMS files (KYC documents, salary slips, ESOP grant letters and
 * the uploaded Excel sheets) in a Google Drive folder instead of Supabase
 * storage. The HRMS keeps only the Drive file id.
 *
 * Every call carries the person's HRMS sign-in token; the bridge checks it
 * with Supabase before doing anything:
 *   - employees can only upload their own KYC (named and filed automatically)
 *     and open files that belong to them;
 *   - admins can upload salary slips, grant letters and sheets, and open any
 *     HRMS file.
 *
 * Setup: see "Storage & documents" in the HRMS admin (Settings).
 * Script properties: SUPABASE_URL, SUPABASE_ANON_KEY, ROOT_FOLDER_ID
 */
var APP = 'altius-hrms';

function doGet() {
  return out_({ ok: true, service: 'Altius HRMS Drive bridge' });
}

function doPost(e) {
  try {
    var req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var user = verify_(req.token);
    var fn = ACTIONS[req.action];
    if (!fn) throw new Error('Unknown action');
    var res = fn(req, user);
    res.ok = true;
    return out_(res);
  } catch (err) {
    return out_({ ok: false, error: String((err && err.message) || err) });
  }
}

var ACTIONS = {
  // Check the connection
  ping: function (req, user) {
    var root = root_();
    return { user: user.full_name, admin: user.isAdmin, folder: root.getName(), folderUrl: root.getUrl() };
  },

  // Save a file. KYC: {kind:'kyc', label, ext, mime, data, owner?}; other files (admin): {folder:[...], name, mime, data, owner?}
  upload: function (req, user) {
    var path, owner, name, replace;
    if (req.kind === 'kyc') {
      var person = user;
      if (req.owner && req.owner !== user.id) {
        if (!user.isAdmin) throw new Error('Not allowed');
        person = profile_(req.owner, req.token);
      }
      path = ['KYC', person.full_name + (person.employee_code ? ' - ' + person.employee_code : '')];
      owner = person.id;
      name = person.full_name + ' - ' + clean_(req.label || 'Document') + '.' + String(req.ext || 'pdf').replace(/[^a-z0-9]/gi, '').toLowerCase();
      replace = 'rename';
    } else {
      if (!user.isAdmin) throw new Error('Only admin can do this');
      if (!req.folder || !req.folder.length) throw new Error('Folder missing');
      path = req.folder;
      owner = req.owner || '';
      name = clean_(req.name || 'File');
      replace = req.replace ? 'trash' : 'keep';
    }
    if (!req.data) throw new Error('The file is empty');
    var folder = folder_(path, req.kind === 'kyc' ? owner : '');
    var same = folder.getFilesByName(name);
    while (same.hasNext()) {
      var old = same.next();
      if (meta_(old).app !== APP) continue;
      if (replace === 'trash') old.setTrashed(true);
      else if (replace === 'rename') old.setName(name.replace(/(\.[a-z0-9]+)?$/i, ' (replaced ' + Utilities.formatDate(new Date(), 'Asia/Kolkata', 'dd-MM-yyyy HHmm') + ')$1'));
    }
    var blob = Utilities.newBlob(Utilities.base64Decode(req.data), req.mime || 'application/octet-stream', name);
    var file = folder.createFile(blob);
    file.setDescription(JSON.stringify({ app: APP, owner: owner, kind: req.kind || 'file', by: user.id }));
    return { id: file.getId(), name: file.getName(), url: file.getUrl(), folderUrl: folder.getUrl() };
  },

  // Open a file: the owner or an admin
  get: function (req, user) {
    var file = DriveApp.getFileById(req.id);
    var m = meta_(file);
    if (m.app !== APP) throw new Error('Not an HRMS file');
    if (!user.isAdmin && m.owner !== user.id) throw new Error('Not allowed');
    var blob = file.getBlob();
    return { name: file.getName(), mime: blob.getContentType(), data: Utilities.base64Encode(blob.getBytes()), url: user.isAdmin ? file.getUrl() : null };
  },

  // Move a file to the Drive bin (admin)
  remove: function (req, user) {
    if (!user.isAdmin) throw new Error('Only admin can do this');
    var file = DriveApp.getFileById(req.id);
    if (meta_(file).app !== APP) throw new Error('Not an HRMS file');
    file.setTrashed(true);
    return {};
  },
};

function cfg_(k) {
  var v = PropertiesService.getScriptProperties().getProperty(k);
  if (!v) throw new Error('The Drive bridge is missing the script property ' + k);
  return v;
}
function root_() { return DriveApp.getFolderById(cfg_('ROOT_FOLDER_ID')); }

// Checks the HRMS sign-in token with Supabase and loads the person's profile
function verify_(token) {
  if (!token) throw new Error('Not signed in');
  var base = cfg_('SUPABASE_URL').replace(/\/$/, '');
  var h = { apikey: cfg_('SUPABASE_ANON_KEY'), Authorization: 'Bearer ' + token };
  var u = UrlFetchApp.fetch(base + '/auth/v1/user', { headers: h, muteHttpExceptions: true });
  if (u.getResponseCode() !== 200) throw new Error('Your session has expired. Please sign in again.');
  var p = profile_(JSON.parse(u.getContentText()).id, token);
  p.isAdmin = p.role === 'admin' && p.status === 'active';
  return p;
}
function profile_(id, token) {
  var base = cfg_('SUPABASE_URL').replace(/\/$/, '');
  var h = { apikey: cfg_('SUPABASE_ANON_KEY'), Authorization: 'Bearer ' + token };
  var r = UrlFetchApp.fetch(base + '/rest/v1/profiles?select=id,role,status,full_name,employee_code&id=eq.' + encodeURIComponent(id), { headers: h, muteHttpExceptions: true });
  var rows = JSON.parse(r.getContentText() || '[]');
  if (!rows.length) throw new Error('Profile not found');
  return rows[0];
}

// Finds or creates root/path[0]/path[1]/…; the last folder can be tied to an owner
function folder_(path, owner) {
  var f = root_();
  for (var i = 0; i < path.length; i++) {
    var name = clean_(path[i]);
    var last = i === path.length - 1;
    var it = f.getFoldersByName(name), next = null;
    while (it.hasNext()) {
      var c = it.next();
      if (!last || !owner || meta_(c).owner === owner) { next = c; break; }
    }
    if (!next) {
      next = f.createFolder(name);
      next.setDescription(JSON.stringify({ app: APP, owner: last ? owner : '' }));
    }
    f = next;
  }
  return f;
}
function meta_(item) {
  try { return JSON.parse(item.getDescription() || '{}') || {}; } catch (e) { return {}; }
}
function clean_(s) {
  return String(s || '').replace(/[\\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 150) || 'Untitled';
}
function out_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
