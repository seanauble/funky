/// Spots a fraternity, sorority or college in a party/event/tailgate's name
/// (or a Story's caption) — "TKE Late Night", "Tau Kappa Epsilon mixer",
/// "Penn State tailgate" — so its letters can sit in the corner of the
/// cover photo in that organization's colors.
///
/// Pure Dart (colors are 0xAARRGGBB ints) so it can be tested on its own.
/// Colors are each group's official ones as best known; easy to tweak here.
library;

enum OrgKind { greek, college }

class OrgBadge {
  /// What's printed: Greek letters ("ΤΚΕ") or the school's short name ("PSU").
  final String letters;
  final String name;
  final int bg;
  final int fg;
  final OrgKind kind;
  const OrgBadge(this.letters, this.name, this.bg, this.fg, this.kind);

  @override
  String toString() => '$letters ($name)';
}

class _Org {
  final String letters;
  final String name;
  final int bg;
  final int fg;
  // Lowercase phrases matched as whole words ("sig ep", "tau kappa epsilon").
  final List<String> phrases;
  // Matched only in capitals as a whole word ("TKE", "KA", "DG").
  final List<String> caps;
  const _Org(this.letters, this.name, this.bg, this.fg, this.phrases, [this.caps = const []]);
}

// ---- Fraternities & sororities ------------------------------------------

const _greek = <_Org>[
  // Fraternities
  _Org('ΤΚΕ', 'Tau Kappa Epsilon', 0xFFB0122A, 0xFFD9D9D9, ['tau kappa epsilon', 'teke', 'tekes', 'tke'], ['TKE']),
  _Org('ΣΑΕ', 'Sigma Alpha Epsilon', 0xFF4B2E83, 0xFFD4B551, ['sigma alpha epsilon', 'sae'], ['SAE']),
  _Org('ΣΧ', 'Sigma Chi', 0xFF1F3E7C, 0xFFD4B551, ['sigma chi', 'sig chi', 'sigma chis']),
  _Org('ΣΝ', 'Sigma Nu', 0xFF111111, 0xFFD4AF37, ['sigma nu', 'sig nu']),
  _Org('ΣΦΕ', 'Sigma Phi Epsilon', 0xFF5B2C83, 0xFFE0283C, ['sigma phi epsilon', 'sig ep', 'sigep', 'sig eps'], ['SPE']),
  _Org('ΠΚΑ', 'Pi Kappa Alpha', 0xFF7B1E23, 0xFFD4B551, ['pi kappa alpha', 'pike', 'pikes'], ['PIKE']),
  _Org('ΚΣ', 'Kappa Sigma', 0xFFC8102E, 0xFFFFFFFF, ['kappa sigma', 'kappa sig', 'kap sig']),
  _Org('ΦΔΘ', 'Phi Delta Theta', 0xFF0B5CAD, 0xFFFFFFFF, ['phi delta theta', 'phi delt', 'phi delts']),
  _Org('ΒΘΠ', 'Beta Theta Pi', 0xFF1E5AA8, 0xFFF6B5C6, ['beta theta pi']),
  _Org('ΔΤΔ', 'Delta Tau Delta', 0xFF5B2C83, 0xFFD4B551, ['delta tau delta', 'delts'], ['DTD']),
  _Org('ΛΧΑ', 'Lambda Chi Alpha', 0xFF4B2E83, 0xFFD4B551, ['lambda chi alpha', 'lambda chi', 'lambda chis']),
  _Org('ΑΤΩ', 'Alpha Tau Omega', 0xFF0B4F8A, 0xFFD4B551, ['alpha tau omega'], ['ATO']),
  _Org('ΦΓΔ', 'Phi Gamma Delta', 0xFF5B2C83, 0xFFFFFFFF, ['phi gamma delta', 'fiji'], ['FIJI']),
  _Org('ΔΥ', 'Delta Upsilon', 0xFF0F52BA, 0xFFD4B551, ['delta upsilon']),
  _Org('ΘΧ', 'Theta Chi', 0xFFC8102E, 0xFFFFFFFF, ['theta chi']),
  _Org('ΖΒΤ', 'Zeta Beta Tau', 0xFF002855, 0xFF8EC3EA, ['zeta beta tau', 'zbt'], ['ZBT']),
  _Org('ΑΕΠ', 'Alpha Epsilon Pi', 0xFF1C3F94, 0xFFF2C230, ['alpha epsilon pi', 'aepi'], ['AEPI', 'AEPi']),
  _Org('ΠΚΦ', 'Pi Kappa Phi', 0xFF1E3F8F, 0xFFFFD100, ['pi kappa phi', 'pi kapp', 'pi kapps']),
  _Org('ΦΚΨ', 'Phi Kappa Psi', 0xFF2F5233, 0xFFFFFFFF, ['phi kappa psi', 'phi psi']),
  _Org('ΦΚΣ', 'Phi Kappa Sigma', 0xFF111111, 0xFFD4B551, ['phi kappa sigma']),
  _Org('ΦΚΤ', 'Phi Kappa Tau', 0xFFA51C30, 0xFFD4B551, ['phi kappa tau', 'phi tau']),
  _Org('ΚΑ', 'Kappa Alpha Order', 0xFF990000, 0xFFD4B551, ['kappa alpha order'], ['KA']),
  _Org('ΣΠ', 'Sigma Pi', 0xFFB57EDC, 0xFF2D1B4E, ['sigma pi']),
  _Org('ΔΧ', 'Delta Chi', 0xFFC8102E, 0xFFF0DC82, ['delta chi', 'd chi']),
  _Org('ΧΦ', 'Chi Phi', 0xFF003087, 0xFFE0283C, ['chi phi']),
  _Org('ΧΨ', 'Chi Psi', 0xFF5B2C83, 0xFFD4B551, ['chi psi']),
  _Org('ΨΥ', 'Psi Upsilon', 0xFF7B1E23, 0xFFD4B551, ['psi upsilon', 'psi u']),
  _Org('ΔΚΕ', 'Delta Kappa Epsilon', 0xFF0057B8, 0xFFD4B551, ['delta kappa epsilon', 'deke', 'dekes'], ['DKE']),
  _Org('ΦΣΚ', 'Phi Sigma Kappa', 0xFFB5179E, 0xFFE6E6E6, ['phi sigma kappa', 'phi sig', 'phi sigs']),
  _Org('ΑΣΦ', 'Alpha Sigma Phi', 0xFF8C1515, 0xFFC9C9C9, ['alpha sigma phi', 'alpha sig']),
  _Org('ΑΧΡ', 'Alpha Chi Rho', 0xFF7B1E23, 0xFFD4B551, ['alpha chi rho'], ['AXP']),
  _Org('ΘΞ', 'Theta Xi', 0xFF2F6DB5, 0xFFFFFFFF, ['theta xi']),
  _Org('ΔΣΦ', 'Delta Sigma Phi', 0xFF2E8B57, 0xFFFFFFFF, ['delta sigma phi', 'delta sig']),
  _Org('ΣΑΜ', 'Sigma Alpha Mu', 0xFF5B2C83, 0xFFFFFFFF, ['sigma alpha mu']),
  _Org('ΤΕΦ', 'Tau Epsilon Phi', 0xFF7D5BA6, 0xFFFFFFFF, ['tau epsilon phi'], ['TEP']),
  _Org('ΑΓΡ', 'Alpha Gamma Rho', 0xFF1E6B35, 0xFFF2C230, ['alpha gamma rho'], ['AGR']),
  _Org('ΑΦΑ', 'Alpha Phi Alpha', 0xFF111111, 0xFFD4B551, ['alpha phi alpha']),
  _Org('ΚΑΨ', 'Kappa Alpha Psi', 0xFF9E1B32, 0xFFFFF8DC, ['kappa alpha psi', 'nupes']),
  _Org('ΩΨΦ', 'Omega Psi Phi', 0xFF5B2C83, 0xFFD4B551, ['omega psi phi']),
  _Org('ΦΒΣ', 'Phi Beta Sigma', 0xFF0038A8, 0xFFFFFFFF, ['phi beta sigma']),
  _Org('ΙΦΘ', 'Iota Phi Theta', 0xFF3B2F2F, 0xFFD4AF37, ['iota phi theta']),
  // Sororities
  _Org('ΑΦ', 'Alpha Phi', 0xFF5E1224, 0xFFD0D0D0, ['alpha phi', 'a phi', 'aphi']),
  _Org('ΑΧΩ', 'Alpha Chi Omega', 0xFFC8102E, 0xFFFFFFFF, ['alpha chi omega', 'alpha chi', 'a chi o'], ['AXO']),
  _Org('ΑΔΠ', 'Alpha Delta Pi', 0xFF2F7BCB, 0xFFFFFFFF, ['alpha delta pi', 'adpi'], ['ADPI', 'ADPi']),
  _Org('ΑΓΔ', 'Alpha Gamma Delta', 0xFFC8102E, 0xFFF0DC82, ['alpha gamma delta', 'alpha gam'], ['AGD']),
  _Org('ΑΟΠ', 'Alpha Omicron Pi', 0xFFC41E3A, 0xFFFFFFFF, ['alpha omicron pi', 'aopi'], ['AOPI', 'AOPi']),
  _Org('ΑΞΔ', 'Alpha Xi Delta', 0xFF002D72, 0xFF8EC3EA, ['alpha xi delta', 'alpha xi'], ['AXID', 'AXiD']),
  _Org('ΧΩ', 'Chi Omega', 0xFFC41E3A, 0xFFF0E68C, ['chi omega', 'chi o', 'chi os']),
  _Org('ΔΔΔ', 'Delta Delta Delta', 0xFF1F4E9C, 0xFFE0E0E0, ['delta delta delta', 'tri delt', 'tri delta', 'tri delts']),
  _Org('ΔΓ', 'Delta Gamma', 0xFF2B4C9B, 0xFFF9C6D3, ['delta gamma', 'dee gee'], ['DG']),
  _Org('ΔΖ', 'Delta Zeta', 0xFF6B8E23, 0xFFF4C2C2, ['delta zeta'], ['DZ']),
  _Org('ΓΦΒ', 'Gamma Phi Beta', 0xFF5C4033, 0xFFD9BC94, ['gamma phi beta', 'gamma phi']),
  _Org('ΚΑΘ', 'Kappa Alpha Theta', 0xFF111111, 0xFFD4AF37, ['kappa alpha theta']),
  _Org('ΚΔ', 'Kappa Delta', 0xFF556B2F, 0xFFF8F6F0, ['kappa delta'], ['KD']),
  _Org('ΚΚΓ', 'Kappa Kappa Gamma', 0xFF002147, 0xFF8EC3EA, ['kappa kappa gamma', 'kkg'], ['KKG']),
  _Org('ΦΜ', 'Phi Mu', 0xFFD9738F, 0xFFFFFFFF, ['phi mu']),
  _Org('ΠΒΦ', 'Pi Beta Phi', 0xFF722F37, 0xFFB7CCE3, ['pi beta phi', 'pi phi', 'pi phis']),
  _Org('ΣΚ', 'Sigma Kappa', 0xFF800000, 0xFFE6E6FA, ['sigma kappa', 'sig kap']),
  _Org('ΖΤΑ', 'Zeta Tau Alpha', 0xFF5F6A70, 0xFF40E0D0, ['zeta tau alpha', 'zeta', 'zetas'], ['ZTA']),
  _Org('ΑΣΑ', 'Alpha Sigma Alpha', 0xFFC8102E, 0xFFFFFFFF, ['alpha sigma alpha']),
  _Org('ΑΣΤ', 'Alpha Sigma Tau', 0xFF009B77, 0xFFF2C230, ['alpha sigma tau']),
  _Org('ΣΣΣ', 'Sigma Sigma Sigma', 0xFF5B2C83, 0xFFFFFFFF, ['sigma sigma sigma', 'tri sigma', 'tri sig']),
  _Org('ΦΣΣ', 'Phi Sigma Sigma', 0xFF1D4ED8, 0xFFF2C230, ['phi sigma sigma', 'phi sig sig']),
  _Org('ΑΕΦ', 'Alpha Epsilon Phi', 0xFF2E8B57, 0xFFFFFFFF, ['alpha epsilon phi', 'aephi']),
  _Org('ΔΦΕ', 'Delta Phi Epsilon', 0xFF5B2C83, 0xFFF2C230, ['delta phi epsilon', 'dphie', 'd phi e']),
  _Org('ΘΦΑ', 'Theta Phi Alpha', 0xFF1F4E9C, 0xFFF2C230, ['theta phi alpha']),
  _Org('ΑΚΑ', 'Alpha Kappa Alpha', 0xFF6E9B1E, 0xFFFFB6A8, ['alpha kappa alpha']),
  _Org('ΔΣΘ', 'Delta Sigma Theta', 0xFF9E1B32, 0xFFFFF8DC, ['delta sigma theta']),
  _Org('ΖΦΒ', 'Zeta Phi Beta', 0xFF0038A8, 0xFFFFFFFF, ['zeta phi beta']),
  _Org('ΣΓΡ', 'Sigma Gamma Rho', 0xFF0038A8, 0xFFF2C230, ['sigma gamma rho', 'sgrho']),
];

// ---- Colleges ----------------------------------------------------------------

const _colleges = <_Org>[
  _Org('ROWAN', 'Rowan University', 0xFF3E2A1E, 0xFFF1C400, ['rowan', 'rowan university', 'rowan profs']),
  _Org('RU', 'Rutgers', 0xFFCC0033, 0xFFFFFFFF, ['rutgers', 'scarlet knights']),
  _Org('PSU', 'Penn State', 0xFF041E42, 0xFFFFFFFF, ['penn state', 'nittany lions', 'psu'], ['PSU']),
  _Org('TU', 'Temple', 0xFF9D2235, 0xFFFFFFFF, ['temple', 'temple university', 'temple owls']),
  _Org('NOVA', 'Villanova', 0xFF00205B, 0xFFFFFFFF, ['villanova', 'nova']),
  _Org('PENN', 'University of Pennsylvania', 0xFF011F5B, 0xFFE01933, ['upenn', 'penn quakers', 'penn']),
  _Org('DREXEL', 'Drexel', 0xFF07294D, 0xFFFFC600, ['drexel', 'drexel dragons']),
  _Org('PTON', 'Princeton', 0xFF111111, 0xFFE77500, ['princeton', 'princeton tigers']),
  _Org('MU', 'Monmouth', 0xFF041E42, 0xFFFFFFFF, ['monmouth', 'monmouth hawks']),
  _Org('MSU', 'Montclair State', 0xFFCE1126, 0xFFFFFFFF, ['montclair state', 'montclair']),
  _Org('TCNJ', 'The College of New Jersey', 0xFF293F6F, 0xFFC9A54A, ['tcnj', 'college of new jersey'], ['TCNJ']),
  _Org('STOCKTON', 'Stockton', 0xFF002D62, 0xFFFFFFFF, ['stockton', 'stockton ospreys']),
  _Org('SHU', 'Seton Hall', 0xFF004488, 0xFFFFFFFF, ['seton hall'], ['SHU']),
  _Org('KEAN', 'Kean', 0xFF002D72, 0xFFC0C0C0, ['kean', 'kean university']),
  _Org('NJIT', 'NJIT', 0xFFD22630, 0xFFFFFFFF, ['njit'], ['NJIT']),
  _Org('WCU', 'West Chester', 0xFF5B2C83, 0xFFFFC72C, ['west chester', 'wcu', 'golden rams'], ['WCU']),
  _Org('SJU', "Saint Joseph's", 0xFF9E1B32, 0xFFC0C0C0, ['saint joseph s', 'st joseph s', 'st joe s', 'sju'], ['SJU']),
  _Org('LA SALLE', 'La Salle', 0xFF00337F, 0xFFFFC72C, ['la salle']),
  _Org('UD', 'Delaware', 0xFF00539F, 0xFFFFD200, ['delaware', 'blue hens', 'udel']),
  _Org('UMD', 'Maryland', 0xFFE03A3E, 0xFFFFD520, ['maryland', 'terps', 'terrapins', 'umd'], ['UMD']),
  _Org('TU', 'Towson', 0xFF111111, 0xFFFFBB00, ['towson', 'towson tigers']),
  _Org('GU', 'Georgetown', 0xFF041E42, 0xFFA0A0A0, ['georgetown', 'hoyas']),
  _Org('GW', 'George Washington', 0xFF033C5A, 0xFFE8D2A1, ['george washington', 'gwu'], ['GWU']),
  _Org('HU', 'Howard', 0xFF003A63, 0xFFFFFFFF, ['howard university', 'howard bison']),
  _Org('AU', 'American University', 0xFFC4122F, 0xFFFFFFFF, ['american university']),
  _Org('CUSE', 'Syracuse', 0xFFF76900, 0xFF000E54, ['syracuse', 'cuse', 'orange men']),
  _Org('PITT', 'Pitt', 0xFF003594, 0xFFFFB81C, ['pitt', 'pitt panthers', 'pittsburgh panthers']),
  _Org('SBU', 'Stony Brook', 0xFF990000, 0xFFFFFFFF, ['stony brook', 'seawolves']),
  _Org('HOFSTRA', 'Hofstra', 0xFF00337F, 0xFFFFC72C, ['hofstra']),
  _Org('UCONN', 'UConn', 0xFF000E2F, 0xFFFFFFFF, ['uconn']),
  _Org('BC', 'Boston College', 0xFF98002E, 0xFFBC9B6A, ['boston college']),
  _Org('LEHIGH', 'Lehigh', 0xFF653600, 0xFFFFFFFF, ['lehigh']),
  _Org('LAF', 'Lafayette', 0xFF910029, 0xFFFFFFFF, ['lafayette leopards', 'lafayette college']),
  _Org('BUCKNELL', 'Bucknell', 0xFF003865, 0xFFE87722, ['bucknell']),
  _Org('JMU', 'James Madison', 0xFF450084, 0xFFCBB677, ['james madison', 'jmu'], ['JMU']),
  _Org('UVA', 'Virginia', 0xFF232D4B, 0xFFF84C1E, ['uva', 'wahoos', 'virginia cavaliers'], ['UVA']),
  _Org('VT', 'Virginia Tech', 0xFF630031, 0xFFCF4420, ['virginia tech', 'hokies']),
  _Org('WVU', 'West Virginia', 0xFF002855, 0xFFEAAA00, ['west virginia', 'wvu', 'mountaineers'], ['WVU']),
  _Org('M', 'Michigan', 0xFF00274C, 0xFFFFCB05, ['michigan', 'wolverines', 'umich']),
  _Org('MSU', 'Michigan State', 0xFF18453B, 0xFFFFFFFF, ['michigan state']),
  _Org('OSU', 'Ohio State', 0xFFBB0000, 0xFFFFFFFF, ['ohio state', 'buckeyes'], ['OSU']),
  _Org('IU', 'Indiana', 0xFF990000, 0xFFEEEDEB, ['indiana hoosiers', 'hoosiers']),
  _Org('PURDUE', 'Purdue', 0xFF111111, 0xFFCFB991, ['purdue', 'boilermakers']),
  _Org('ILLINI', 'Illinois', 0xFF13294B, 0xFFE84A27, ['illinois', 'illini']),
  _Org('UW', 'Wisconsin', 0xFFC5050C, 0xFFFFFFFF, ['wisconsin', 'badgers']),
  _Org('IOWA', 'Iowa', 0xFF111111, 0xFFFFCD00, ['iowa hawkeyes', 'hawkeyes']),
  _Org('N', 'Nebraska', 0xFFE41C38, 0xFFFDF2D9, ['nebraska', 'huskers', 'cornhuskers']),
  _Org('ND', 'Notre Dame', 0xFF0C2340, 0xFFC99700, ['notre dame', 'fighting irish']),
  _Org('BAMA', 'Alabama', 0xFF9E1B32, 0xFFFFFFFF, ['alabama', 'bama', 'roll tide', 'crimson tide']),
  _Org('AU', 'Auburn', 0xFF0C2340, 0xFFE87722, ['auburn', 'war eagle']),
  _Org('UGA', 'Georgia', 0xFF111111, 0xFFBA0C2F, ['georgia bulldogs', 'uga', 'dawgs'], ['UGA']),
  _Org('LSU', 'LSU', 0xFF461D7C, 0xFFFDD023, ['lsu', 'lsu tigers'], ['LSU']),
  _Org('CLEMSON', 'Clemson', 0xFF522D80, 0xFFF56600, ['clemson']),
  _Org('UF', 'Florida', 0xFF0021A5, 0xFFFA4616, ['florida gators', 'gators']),
  _Org('FSU', 'Florida State', 0xFF782F40, 0xFFCEB888, ['florida state', 'fsu', 'seminoles', 'noles'], ['FSU']),
  _Org('U', 'Miami', 0xFF005030, 0xFFF47321, ['miami hurricanes']),
  _Org('UT', 'Texas', 0xFFBF5700, 0xFFFFFFFF, ['texas longhorns', 'longhorns', 'hook em']),
  _Org('TAMU', 'Texas A&M', 0xFF500000, 0xFFFFFFFF, ['texas a m', 'aggies', 'tamu']),
  _Org('OU', 'Oklahoma', 0xFF841617, 0xFFFDF9D8, ['oklahoma', 'sooners']),
  _Org('VOLS', 'Tennessee', 0xFFFF8200, 0xFFFFFFFF, ['tennessee', 'vols']),
  _Org('UK', 'Kentucky', 0xFF0033A0, 0xFFFFFFFF, ['kentucky', 'kentucky wildcats']),
  _Org('OLE MISS', 'Ole Miss', 0xFF14213D, 0xFFCE1126, ['ole miss']),
  _Org('USC', 'USC', 0xFF990000, 0xFFFFCC00, ['usc'], ['USC']),
  _Org('UO', 'Oregon', 0xFF154733, 0xFFFEE123, ['oregon ducks', 'go ducks']),
  _Org('UNC', 'North Carolina', 0xFF7BAFD4, 0xFF13294B, ['unc', 'tar heels', 'north carolina'], ['UNC']),
  _Org('DUKE', 'Duke', 0xFF003087, 0xFFFFFFFF, ['duke university', 'blue devils']),
  _Org('NCSU', 'NC State', 0xFFCC0000, 0xFFFFFFFF, ['nc state', 'wolfpack']),
];

// ---- Matching -------------------------------------------------------------

const _greekLetterNames = <String, String>{
  'α': 'alpha', 'β': 'beta', 'γ': 'gamma', 'δ': 'delta', 'ε': 'epsilon', 'ζ': 'zeta',
  'η': 'eta', 'θ': 'theta', 'ι': 'iota', 'κ': 'kappa', 'λ': 'lambda', 'μ': 'mu',
  'ν': 'nu', 'ξ': 'xi', 'ο': 'omicron', 'π': 'pi', 'ρ': 'rho', 'σ': 'sigma', 'ς': 'sigma',
  'τ': 'tau', 'υ': 'upsilon', 'φ': 'phi', 'χ': 'chi', 'ψ': 'psi', 'ω': 'omega',
};

/// Lowercase words separated by single spaces, padded with a space on each
/// side; Greek letters are spelled out ("ΤΚΕ" -> " tau kappa epsilon ").
String _normalize(String text) {
  final b = StringBuffer(' ');
  for (final rune in text.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final greek = _greekLetterNames[ch];
    if (greek != null) {
      b.write(' $greek ');
    } else if ((rune >= 0x61 && rune <= 0x7A) || (rune >= 0x30 && rune <= 0x39)) {
      b.write(ch);
    } else {
      b.write(' ');
    }
  }
  b.write(' ');
  return b.toString().replaceAll(RegExp(r' +'), ' ');
}

class _Phrase {
  final String text;
  final _Org org;
  const _Phrase(this.text, this.org);
}

List<_Phrase> _phrasesFor(List<_Org> orgs) {
  final out = <_Phrase>[
    for (final o in orgs)
      for (final p in o.phrases) _Phrase(' $p ', o),
  ];
  // Longest first, so "phi sig sig" wins over "phi sig", "penn state" over "penn".
  out.sort((a, b) => b.text.length.compareTo(a.text.length));
  return out;
}

final _greekPhrases = _phrasesFor(_greek);
final _collegePhrases = _phrasesFor(_colleges);

OrgBadge _badge(_Org o, OrgKind kind) => OrgBadge(o.letters, o.name, o.bg, o.fg, kind);

OrgBadge? _find(String text, List<_Org> orgs, List<_Phrase> phrases, OrgKind kind) {
  if (text.trim().isEmpty) return null;
  // Capitals-only abbreviations first ("TKE", "KA").
  final words = text.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty).toSet();
  for (final o in orgs) {
    for (final c in o.caps) {
      if (words.contains(c)) return _badge(o, kind);
    }
  }
  final norm = _normalize(text);
  for (final p in phrases) {
    if (norm.contains(p.text)) return _badge(p.org, kind);
  }
  return null;
}

OrgBadge? detectGreek(String text) => _find(text, _greek, _greekPhrases, OrgKind.greek);

OrgBadge? detectCollege(String text) => _find(text, _colleges, _collegePhrases, OrgKind.college);

/// The badge for something named [text] (a place's name, an event's title,
/// a Story's caption). [kind] is the place kind's name ('tailgate', 'frat',
/// 'party', 'event', 'bar', 'club'...): tailgates look for a college first,
/// everything else for Greek letters first. Bars and clubs only ever get
/// Greek letters (a "TKE takeover"), never a school just for being nearby.
OrgBadge? orgBadgeFor(String? text, {String? kind}) {
  if (text == null || text.trim().isEmpty) return null;
  final key = '$kind|$text';
  if (_cache.containsKey(key)) return _cache[key];
  final OrgBadge? found;
  if (kind == 'bar' || kind == 'club' || kind == 'area') {
    found = detectGreek(text);
  } else if (kind == 'tailgate') {
    found = detectCollege(text) ?? detectGreek(text);
  } else {
    found = detectGreek(text) ?? detectCollege(text);
  }
  if (_cache.length > 500) _cache.clear();
  _cache[key] = found;
  return found;
}

final _cache = <String, OrgBadge?>{};
