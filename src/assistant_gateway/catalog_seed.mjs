// Seed catalog. All entries are either original exercises written for this
// project (CC0) or public-domain nursery melodies reduced to four playable
// pitches. No commercial scores, no scraped content. Each seed is validated by
// the shared score compiler at service start; a broken seed fails the boot.
//
// Zone semantics: zone0..3 = the four FSR zones. Zone-based drills sound
// whatever panel group (A/B/octave) the player selected; pitched pieces pin
// the mapping (preset group or custom notes) and the compiler enforces it.

const zone = (z, beats, expression = 0) => ({ zone: z, beats, expression });
const midi = (m, beats, expression = 0) => ({ midi: m, beats, expression });

// MIDI helpers for readability
const C4 = 60, D4 = 62, E4 = 64, F4 = 65, G4 = 67, A4 = 69, B4 = 71, C5 = 72, D5 = 74, E5 = 76, F5 = 77, G5 = 79, A5 = 81;

const SEEDS = [
  {
    schemaVersion: 1, songId: 'rhythm-basic-a', revision: 3, title: '四区基本节奏 A',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编入门练习' },
    difficulty: 1, tags: ['节奏', '入门'], bpm: 90, timeSignature: [4, 4],
    notes: [
      zone(0, 1), zone(0, 1), zone(2, 1), zone(2, 1),
      zone(3, 1), zone(3, 1), zone(2, 2), zone(1, 2)
    ]
  },
  {
    schemaVersion: 1, songId: 'rhythm-basic-b', revision: 2, title: '四区基本节奏 B（反向）',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编入门练习' },
    difficulty: 1, tags: ['节奏', '入门'], bpm: 100, timeSignature: [4, 4],
    notes: [
      zone(3, 0.5), zone(3, 0.5), zone(2, 0.5), zone(1, 0.5),
      zone(1, 1), zone(2, 1), zone(3, 1), zone(0, 2)
    ]
  },
  {
    schemaVersion: 1, songId: 'zone-scale-updown', revision: 2, title: '四区音阶上下行',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编音阶练习' },
    difficulty: 1, tags: ['音阶', '入门'], bpm: 80, timeSignature: [4, 4],
    notes: [
      zone(0, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5),
      zone(3, 0.5), zone(2, 0.5), zone(1, 0.5), zone(0, 1)
    ]
  },
  {
    schemaVersion: 1, songId: 'hold-sustain', revision: 2, title: '长音保持练习',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编保持练习' },
    difficulty: 1, tags: ['保持', '慢速'], bpm: 72, timeSignature: [4, 4],
    notes: [
      zone(0, 4), zone(1, 4), zone(2, 4), zone(3, 4),
      zone(3, 2), zone(2, 2), zone(1, 2), zone(0, 2)
    ]
  },
  {
    schemaVersion: 1, songId: 'expr-glide-vibrato', revision: 2, title: '表达练习：滑音与颤音',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编表达练习' },
    difficulty: 2, tags: ['表达', '摇杆'], bpm: 76, timeSignature: [4, 4],
    notes: [
      zone(0, 2, 0), zone(1, 2, 1), zone(2, 2, 2), zone(3, 2, 0),
      zone(3, 2, 1), zone(2, 2, 2), zone(1, 2, 0), zone(0, 2, 1)
    ]
  },
  {
    schemaVersion: 1, songId: 'tempo-slow-60', revision: 1, title: '慢速稳定节奏（60 BPM）',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编慢速练习' },
    difficulty: 1, tags: ['慢速', '节奏'], bpm: 60, timeSignature: [4, 4],
    notes: [
      zone(0, 1), zone(1, 1), zone(0, 1), zone(1, 1),
      zone(2, 1), zone(3, 1), zone(2, 1), zone(3, 1),
      zone(0, 1), zone(2, 1), zone(0, 1), zone(2, 1)
    ]
  },
  {
    schemaVersion: 1, songId: 'tempo-fast-120', revision: 1, title: '快速反应练习（120 BPM）',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编快速练习' },
    difficulty: 3, tags: ['快速', '反应'], bpm: 120, timeSignature: [4, 4],
    notes: [
      zone(0, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5),
      zone(3, 0.5), zone(2, 0.5), zone(1, 0.5), zone(0, 0.5),
      zone(1, 0.25), zone(1, 0.25), zone(2, 0.25), zone(2, 0.25),
      zone(3, 0.5), zone(0, 0.5), zone(2, 1), zone(0, 1)
    ]
  },
  {
    schemaVersion: 1, songId: 'arpeggio-flow', revision: 2, title: '琶音流动练习',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编琶音练习' },
    difficulty: 2, tags: ['琶音', '流动力'], bpm: 96, timeSignature: [4, 4],
    notes: [
      zone(0, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5),
      zone(1, 0.5), zone(2, 0.5), zone(3, 0.5), zone(0, 0.5),
      zone(2, 0.5), zone(3, 0.5), zone(0, 0.5), zone(1, 0.5),
      zone(3, 0.5), zone(0, 0.5), zone(1, 0.5), zone(2, 1.5)
    ]
  },
  {
    schemaVersion: 1, songId: 'endurance-marathon-48', revision: 1, title: '循环耐力练习（48步·分段）',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编耐力练习' },
    difficulty: 3, tags: ['耐力', '分段'], bpm: 104, timeSignature: [4, 4],
    notes: [
      zone(0, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5), zone(0, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5),
      zone(3, 0.5), zone(2, 0.5), zone(1, 0.5), zone(0, 0.5), zone(3, 0.5), zone(2, 0.5), zone(1, 0.5), zone(0, 0.5),
      zone(1, 0.5), zone(1, 0.5), zone(2, 0.5), zone(2, 0.5), zone(3, 0.5), zone(3, 0.5), zone(0, 0.5), zone(0, 0.5),
      zone(0, 1), zone(2, 1), zone(1, 1), zone(3, 1), zone(0, 1), zone(2, 1), zone(1, 1), zone(3, 1),
      zone(0, 0.5), zone(3, 0.5), zone(1, 0.5), zone(2, 0.5), zone(3, 0.5), zone(0, 0.5), zone(2, 0.5), zone(1, 0.5),
      zone(0, 1), zone(1, 1), zone(2, 1), zone(3, 1), zone(0, 1), zone(1, 1), zone(2, 1), zone(3, 2)
    ]
  },
  {
    schemaVersion: 1, songId: 'interplay-zones', revision: 2, title: '区域联动综合练习',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》自编综合练习' },
    difficulty: 2, tags: ['综合', '节奏'], bpm: 88, timeSignature: [4, 4],
    notes: [
      zone(0, 1), zone(2, 0.5), zone(2, 0.5), zone(3, 1), zone(1, 1),
      zone(1, 0.5), zone(0, 0.5), zone(2, 1), zone(3, 0.5), zone(3, 0.5),
      zone(0, 1, 1), zone(1, 1, 1), zone(2, 1, 2), zone(3, 1, 2),
      zone(3, 0.5), zone(2, 0.5), zone(1, 0.5), zone(0, 0.5), zone(0, 2)
    ]
  },
  {
    // Public-domain nursery tune; all four pitches (C4 D4 E4 G4) are exactly
    // preset group A, so no custom mapping is needed.
    schemaVersion: 1, songId: 'mary-lamb-preset-a', revision: 4, title: '玛丽有只小羊羔（组A四音）',
    source: { type: 'public-domain', license: 'Public Domain', attribution: '传统儿歌，四音改编' },
    difficulty: 2, tags: ['旋律', '儿歌', '组A'], bpm: 100, timeSignature: [4, 4],
    notes: [
      midi(E4, 1), midi(D4, 1), midi(C4, 1), midi(D4, 1),
      midi(E4, 1), midi(E4, 1), midi(E4, 2),
      midi(D4, 1), midi(D4, 1), midi(D4, 2),
      midi(E4, 1), midi(G4, 1), midi(G4, 2),
      midi(E4, 1), midi(D4, 1), midi(C4, 1), midi(D4, 1),
      midi(E4, 1), midi(E4, 1), midi(E4, 1), midi(E4, 1),
      midi(D4, 1), midi(D4, 1), midi(E4, 1), midi(D4, 1),
      midi(C4, 4)
    ]
  },
  {
    // Ode to Joy, first phrase: D E F G — four pitches that fit NO preset
    // group, so the compiler demands custom note fields 1-4. This is the
    // honest "requires mapping configuration" demo.
    schemaVersion: 1, songId: 'ode-phrase-custom', revision: 2, title: '欢乐颂首句（需自定义四音）',
    source: { type: 'public-domain', license: 'Public Domain', attribution: '贝多芬《欢乐颂》主题首句，公版' },
    difficulty: 2, tags: ['旋律', '古典', '自定义映射'], bpm: 112, timeSignature: [4, 4],
    notes: [
      midi(E4, 1), midi(E4, 1), midi(F4, 1), midi(G4, 1),
      midi(G4, 1), midi(F4, 1), midi(E4, 1), midi(D4, 1),
      midi(E4, 1.5), midi(E4, 0.5), midi(D4, 2)
    ]
  },
  {
    // Original melody confined to preset group A pitches.
    schemaVersion: 1, songId: 'yunsheng-prelude', revision: 3, title: '《云声引》自编练习曲',
    source: { type: 'original', license: 'CC0-1.0', attribution: '《弦触·云声》原创练习曲' },
    difficulty: 3, tags: ['旋律', '原创', '组A'], bpm: 92, timeSignature: [4, 4],
    notes: [
      midi(C4, 1), midi(E4, 1), midi(G4, 1), midi(E4, 1),
      midi(D4, 1), midi(G4, 2), midi(E4, 1), midi(C4, 1),
      midi(D4, 1.5), midi(E4, 0.5), midi(G4, 1), midi(E4, 1),
      midi(D4, 1), midi(C4, 2), midi(G4, 1), midi(E4, 1),
      midi(D4, 1), midi(E4, 1), midi(G4, 1.5), midi(E4, 0.5),
      midi(D4, 1), midi(C4, 3)
    ]
  },
  {
    // Six distinct pitches: intentionally NOT adaptable to four zones. Served
    // so the catalog UI can show a real mapping-failure explanation instead of
    // silently hiding the limit.
    schemaVersion: 1, songId: 'twinkle-six-pitches', revision: 1, title: '小星星完整版（六音·不可四区适配）',
    source: { type: 'public-domain', license: 'Public Domain', attribution: '法国传统儿歌，公版' },
    difficulty: 2, tags: ['旋律', '儿歌', '不适配示例'], bpm: 96, timeSignature: [4, 4],
    notes: [
      midi(C4, 1), midi(C4, 1), midi(G4, 1), midi(G4, 1), midi(A4, 1), midi(A4, 1), midi(G4, 2),
      midi(F4, 1), midi(F4, 1), midi(E4, 1), midi(E4, 1), midi(D4, 1), midi(D4, 1), midi(C4, 2)
    ]
  }
];

export { SEEDS };
