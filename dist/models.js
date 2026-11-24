import { readdir, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { MODEL_PATTERN } from './config.js';
import { ExecError, run } from './exec.js';
// Claude Code 모델 캐시(~/.claude/cache/model-catalog)를 읽지 못할 때 쓰는 목록.
// 별칭(opus 등)은 새 모델이 나오면 가리키는 대상이 바뀌어 화면의 버전과 어긋날 수 있다. 그래서 버전이 고정된 전체 이름을 쓴다.
// Claude Code 2.1.331의 캐시 주 목록과 같다(2026-11-24).
export const CLAUDE_FALLBACK_MODELS = [
    { id: 'claude-fable-5-2', label: 'Fable 5.2', description: 'claude-fable-5-2' },
    { id: 'claude-opus-5-5', label: 'Opus 5.5', description: 'claude-opus-5-5' },
    { id: 'claude-sonnet-5-5', label: 'Sonnet 5.5', description: 'claude-sonnet-5-5' },
    { id: 'claude-haiku-5-5', label: 'Haiku 5.5', description: 'claude-haiku-5-5' },
];
const CODEX_TIMEOUT_MS = 20_000;
function asRecord(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : null;
}
/**
 * Claude Code가 계정별로 받아 두는 모델 카탈로그 캐시를 해석한다. 문서화되지 않은 형식이라, 모양이 다르면 null을 돌려 고정 목록을 쓰게 한다.
 * Claude Code의 /model 첫 화면과 같게 section이 main인 모델만 남기고, 이전 모델(overflow)과 숨김 모델(masked)은 뺀다.
 */
export function parseClaudeCatalog(json, maskedIds = new Set()) {
    let root;
    try {
        root = asRecord(JSON.parse(json));
    }
    catch {
        return null;
    }
    const catalog = asRecord(root?.['catalog']);
    if (!root || !catalog || catalog['surface'] !== 'cc')
        return null;
    const list = asRecord(catalog['config'])?.['models'];
    if (!Array.isArray(list))
        return null;
    const models = [];
    const seen = new Set();
    for (const item of list) {
        const value = asRecord(item);
        const id = value?.['id'];
        if (!value || typeof id !== 'string' || !MODEL_PATTERN.test(id) || seen.has(id) || maskedIds.has(id))
            continue;
        if (value['section'] !== 'main')
            continue;
        seen.add(id);
        const label = typeof value['name'] === 'string' && value['name'] !== '' ? value['name'] : id;
        const description = typeof value['description'] === 'string' ? value['description'] : '';
        models.push({ id, label, description });
    }
    if (models.length === 0)
        return null;
    // 리뷰는 --setting-sources project로 실행해 개인 설정의 model을 읽지 않는다.
    // 그래서 계정 기본값(global_default)일 때만 리뷰에서도 같은 모델을 쓴다고 보고, 다른 출처면 기본 모델을 알 수 없는 것으로 둔다.
    const state = asRecord(catalog['state']);
    const selected = state?.['model'];
    const defaultModel = state?.['selection_source'] === 'global_default' && typeof selected === 'string' && MODEL_PATTERN.test(selected) ? selected : null;
    const fetchedAt = typeof root['fetchedAt'] === 'number' ? root['fetchedAt'] : 0;
    return { models, defaultModel, fetchedAt };
}
/** 숨김 모델 목록(masked-ids.json의 ids). 없거나 모양이 다르면 빈 집합. */
export function parseMaskedIds(json) {
    try {
        const ids = asRecord(JSON.parse(json))?.['ids'];
        return new Set(Array.isArray(ids) ? ids.filter((id) => typeof id === 'string') : []);
    }
    catch {
        return new Set();
    }
}
async function readClaudeCatalog() {
    const configDir = process.env['CLAUDE_CONFIG_DIR'] || join(homedir(), '.claude');
    const dir = join(configDir, 'cache', 'model-catalog');
    const names = await readdir(dir).catch(() => []);
    const masked = parseMaskedIds(await readFile(join(dir, 'masked-ids.json'), 'utf8').catch(() => ''));
    // 계정마다 파일이 하나씩 생긴다. 여러 계정으로 로그인했던 PC면 가장 최근에 받은 카탈로그를 쓴다.
    // published-*.json은 전체 공개 목록이라 계정에서 쓸 수 있는 모델과 다를 수 있어 읽지 않는다.
    const candidates = names.filter((name) => name.endsWith('.json') && name !== 'masked-ids.json' && !name.startsWith('published'));
    let latest = null;
    for (const name of candidates) {
        const catalog = parseClaudeCatalog(await readFile(join(dir, name), 'utf8').catch(() => ''), masked);
        if (catalog && (!latest || catalog.fetchedAt > latest.fetchedAt))
            latest = catalog;
    }
    return latest;
}
async function listClaudeModels() {
    const catalog = await readClaudeCatalog();
    if (catalog)
        return { engine: 'claude', models: catalog.models, defaultModel: catalog.defaultModel, error: null };
    // Claude Code에는 모델 목록 명령이 없어, 캐시가 없으면(한 번도 실행하지 않은 PC 등) 고정 목록을 쓴다. 기본 모델은 알 수 없다.
    return { engine: 'claude', models: [...CLAUDE_FALLBACK_MODELS], defaultModel: null, error: null };
}
/**
 * `codex debug models` 출력에서 모델 선택 화면에 보여 줄 항목을 고른다.
 * Codex 화면의 /model 목록과 같게 visibility가 list인 모델만 남기고, 카탈로그 순서(priority)를 따른다.
 */
export function parseCodexModels(json) {
    const parsed = JSON.parse(json);
    const list = parsed !== null && typeof parsed === 'object' ? parsed['models'] : undefined;
    if (!Array.isArray(list))
        return [];
    const models = [];
    const seen = new Set();
    for (const item of list) {
        if (item === null || typeof item !== 'object')
            continue;
        const value = item;
        const id = value['slug'];
        // config의 model 검증을 통과하지 못하는 이름은 저장할 수 없으므로 목록에서 뺀다.
        if (typeof id !== 'string' || !MODEL_PATTERN.test(id) || seen.has(id))
            continue;
        if (value['visibility'] !== 'list')
            continue;
        seen.add(id);
        const label = typeof value['display_name'] === 'string' && value['display_name'] !== '' ? value['display_name'] : id;
        const description = typeof value['description'] === 'string' ? value['description'] : '';
        models.push({ id, label, description });
    }
    return models;
}
/** config.toml 맨 위(첫 [표] 앞)의 `model = "..."` 값. 형식이 다르거나 없으면 null. */
export function parseCodexDefaultModel(toml) {
    for (const line of toml.split('\n')) {
        const trimmed = line.trim();
        if (trimmed.startsWith('['))
            break;
        const match = /^model\s*=\s*["']([^"']+)["']/.exec(trimmed);
        if (match?.[1] && MODEL_PATTERN.test(match[1]))
            return match[1];
    }
    return null;
}
async function readCodexDefaultModel() {
    const codexHome = process.env['CODEX_HOME'] || join(homedir(), '.codex');
    const toml = await readFile(join(codexHome, 'config.toml'), 'utf8').catch(() => null);
    return toml === null ? null : parseCodexDefaultModel(toml);
}
async function listCodexModels() {
    // `codex debug models`는 로그인한 계정에서 쓸 수 있는 모델 카탈로그를 JSON으로 낸다. 캐시가 있으면 네트워크 없이 바로 끝난다.
    const args = ['debug', 'models'];
    try {
        const result = await run('codex', args, { timeoutMs: CODEX_TIMEOUT_MS });
        if (result.code !== 0 || result.timedOut)
            throw new ExecError('codex', args, result);
        return { engine: 'codex', models: parseCodexModels(result.stdout), defaultModel: await readCodexDefaultModel(), error: null };
    }
    catch (error) {
        const missing = error.code === 'ENOENT';
        const message = missing ? 'Codex CLI가 설치되지 않았습니다.' : `Codex 모델 목록을 읽지 못했습니다: ${error instanceof Error ? error.message : String(error)}`;
        return { engine: 'codex', models: [], defaultModel: null, error: message };
    }
}
export async function listEngineModels() {
    return Promise.all([listClaudeModels(), listCodexModels()]);
}
