// Catalog service: list / search / filter / detail / compile endpoints over the
// seed catalog, sharing the miniprogram's score compiler (loaded via
// createRequire) so client and server can never disagree about four-zone
// adaptability, 32-step segmentation or BPM conversion.
import { createRequire } from 'node:module';
import { SEEDS } from './catalog_seed.mjs';

const require = createRequire(import.meta.url);
const compiler = require('../wechat_miniprogram/utils/score_compiler.js');

const CATALOG_VERSION = 1;

function createCatalog(options = {}) {
  const seeds = options.seeds ?? SEEDS;
  const compile = options.compile ?? compiler.compileScore;

  // Boot-time validation: a structurally broken seed must fail the service,
  // not silently serve garbage with a hash on it.
  const songs = new Map();
  for (const seed of seeds) {
    const schemaErrors = compiler.validateSchema(seed);
    if (schemaErrors.length) {
      throw Object.assign(new Error(`SEED_INVALID:${seed.songId}:${schemaErrors[0].code}`), { code: 'SEED_INVALID' });
    }
    const contentHash = compiler.scoreContentHash(seed);
    // Adaptation preview with custom-note support assumed: this is what the
    // song NEEDS, independent of any particular device.
    const compiled = compile(seed, { deviceSupportsCustomNotes: true });
    const entry = {
      score: seed,
      contentHash,
      adaptation: compiled.ok
        ? {
            playable: true,
            mapping: compiled.requiredMapping,
            segments: compiled.segments.length,
            stepCount: compiled.stepCount,
            durationSeconds: compiled.durationSeconds,
            pitches: compiled.zonePitchNames
          }
        : {
            playable: false,
            reason: compiled.errors[0].code,
            reasonText: compiled.errors[0].message
          }
    };
    if (songs.has(seed.songId)) throw Object.assign(new Error(`SEED_DUPLICATE:${seed.songId}`), { code: 'SEED_DUPLICATE' });
    songs.set(seed.songId, entry);
  }

  function summary(entry) {
    return {
      schemaVersion: entry.score.schemaVersion,
      songId: entry.score.songId,
      revision: entry.score.revision,
      title: entry.score.title,
      source: entry.score.source,
      difficulty: entry.score.difficulty,
      tags: entry.score.tags,
      bpm: entry.score.bpm,
      timeSignature: entry.score.timeSignature,
      stepCount: entry.score.notes.length,
      contentHash: entry.contentHash,
      adaptation: entry.adaptation
    };
  }

  function list(params = {}) {
    const page = Math.max(1, Number(params.page) || 1);
    const pageSize = Math.min(50, Math.max(1, Number(params.pageSize) || 20));
    let items = Array.from(songs.values());
    const q = typeof params.q === 'string' ? params.q.trim().toLowerCase() : '';
    if (q) {
      items = items.filter(entry => {
        const s = entry.score;
        return s.title.toLowerCase().includes(q) || s.songId.includes(q) ||
          s.tags.some(t => t.toLowerCase().includes(q));
      });
    }
    if (params.difficulty) {
      const d = Number(params.difficulty);
      if (Number.isInteger(d) && d >= 1 && d <= 5) items = items.filter(e => e.score.difficulty === d);
    }
    if (params.maxDifficulty) {
      const d = Number(params.maxDifficulty);
      if (Number.isInteger(d) && d >= 1 && d <= 5) items = items.filter(e => e.score.difficulty <= d);
    }
    if (params.tag) items = items.filter(e => e.score.tags.includes(params.tag));
    if (params.bpmMax) {
      const b = Number(params.bpmMax);
      if (Number.isFinite(b)) items = items.filter(e => e.score.bpm <= b);
    }
    if (params.bpmMin) {
      const b = Number(params.bpmMin);
      if (Number.isFinite(b)) items = items.filter(e => e.score.bpm >= b);
    }
    const sort = params.sort || 'difficulty';
    items.sort((a, b) => {
      if (sort === 'title') return a.score.title.localeCompare(b.score.title, 'zh-Hans-CN');
      if (sort === 'bpm') return a.score.bpm - b.score.bpm;
      return a.score.difficulty - b.score.difficulty || a.score.bpm - b.score.bpm;
    });
    const total = items.length;
    const start = (page - 1) * pageSize;
    return {
      schemaVersion: CATALOG_VERSION,
      page, pageSize, total, totalPages: Math.ceil(total / pageSize) || 1,
      songs: items.slice(start, start + pageSize).map(summary)
    };
  }

  function detail(songId) {
    const entry = songs.get(songId);
    if (!entry) return null;
    return { schemaVersion: CATALOG_VERSION, score: entry.score, contentHash: entry.contentHash, adaptation: entry.adaptation };
  }

  function compileSong(songId, params = {}) {
    const entry = songs.get(songId);
    if (!entry) return null;
    const bpm = params.bpm ? Number(params.bpm) : undefined;
    const compiled = compile(entry.score, {
      bpm,
      deviceSupportsCustomNotes: params.deviceSupportsCustomNotes === true || params.deviceSupportsCustomNotes === '1'
    });
    return { schemaVersion: CATALOG_VERSION, songId, revision: entry.score.revision, bpm: bpm || entry.score.bpm, compiled };
  }

  return {
    version: CATALOG_VERSION,
    size: songs.size,
    list, detail, compileSong,
    contentHash(songId) { const e = songs.get(songId); return e ? e.contentHash : null; }
  };
}

export { createCatalog, compiler };
