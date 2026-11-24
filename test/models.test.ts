import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { MODEL_PATTERN } from '../src/config.ts';
import { CLAUDE_FALLBACK_MODELS, parseClaudeCatalog, parseCodexDefaultModel, parseCodexModels, parseMaskedIds } from '../src/models.ts';

describe('models', () => {
  it('Codex 카탈로그에서 목록에 보이는 모델만 순서대로 고른다', () => {
    const models = parseCodexModels(JSON.stringify({
      models: [
        { slug: 'gpt-a', display_name: 'GPT A', description: '빠름', visibility: 'list' },
        { slug: 'internal', display_name: 'Internal', description: '', visibility: 'hide' },
        { slug: 'gpt-b', visibility: 'list' },
        { slug: 'bad name', display_name: 'Bad', visibility: 'list' },
        { slug: 'gpt-a', display_name: 'GPT A 중복', visibility: 'list' },
        null,
      ],
    }));
    assert.deepEqual(models, [
      { id: 'gpt-a', label: 'GPT A', description: '빠름' },
      { id: 'gpt-b', label: 'gpt-b', description: '' },
    ]);
  });

  it('모양이 다른 출력은 빈 목록으로 본다', () => {
    assert.deepEqual(parseCodexModels('[]'), []);
    assert.deepEqual(parseCodexModels('{"models":{}}'), []);
    assert.throws(() => parseCodexModels('not json'));
  });

  it('Codex config.toml 맨 위의 model만 기본 모델로 읽는다', () => {
    assert.equal(parseCodexDefaultModel('model = "gpt-6.1-sol"\nmodel_reasoning_effort = "xhigh"\n'), 'gpt-6.1-sol');
    assert.equal(parseCodexDefaultModel('# 주석\n  model=\'gpt-a\'\n'), 'gpt-a');
    assert.equal(parseCodexDefaultModel('[profiles.fast]\nmodel = "gpt-b"\n'), null);
    assert.equal(parseCodexDefaultModel('model_provider = "x"\n'), null);
    assert.equal(parseCodexDefaultModel('model = "bad name"\n'), null);
  });

  it('Claude 카탈로그 캐시에서 주 목록만 고르고 숨김 모델을 뺀다', () => {
    const json = JSON.stringify({
      version: 2,
      fetchedAt: 1795511145890,
      catalog: {
        surface: 'cc',
        config: {
          models: [
            { id: 'claude-opus-5-5', name: 'Opus 5.5', description: 'For complex work', section: 'main' },
            { id: 'claude-secret-1', name: 'Secret 1', section: 'main' },
            { id: 'claude-haiku-5-5', section: 'main' },
            { id: 'claude-opus-4-8', name: 'Opus 4.8', section: 'overflow' },
            { id: 'bad id', name: 'Bad', section: 'main' },
          ],
        },
        state: { model: 'claude-opus-5-5', selection_source: 'global_default' },
      },
    });
    assert.deepEqual(parseClaudeCatalog(json, new Set(['claude-secret-1'])), {
      models: [
        { id: 'claude-opus-5-5', label: 'Opus 5.5', description: 'For complex work' },
        { id: 'claude-haiku-5-5', label: 'claude-haiku-5-5', description: '' },
      ],
      defaultModel: 'claude-opus-5-5',
      fetchedAt: 1795511145890,
    });
  });

  it('개인 설정에서 고른 모델은 리뷰 실행에 쓰이지 않아 기본 모델로 보지 않는다', () => {
    const json = JSON.stringify({
      catalog: {
        surface: 'cc',
        config: { models: [{ id: 'claude-opus-5-5', name: 'Opus 5.5', section: 'main' }] },
        state: { model: 'claude-sonnet-5-5', selection_source: 'user_settings' },
      },
    });
    assert.equal(parseClaudeCatalog(json)?.defaultModel, null);
  });

  it('모양이 다른 Claude 캐시는 null로 보고 고정 목록을 쓰게 한다', () => {
    assert.equal(parseClaudeCatalog(''), null);
    assert.equal(parseClaudeCatalog('{"catalog":{"surface":"web","config":{"models":[]}}}'), null);
    assert.equal(parseClaudeCatalog('{"catalog":{"surface":"cc","config":{"models":[{"id":"claude-x","section":"overflow"}]}}}'), null);
    assert.deepEqual([...parseMaskedIds('{"ids":["a",1,"b"]}')], ['a', 'b']);
    assert.deepEqual([...parseMaskedIds('nope')], []);
  });

  it('Claude 고정 목록은 설정의 model 검증을 통과한다', () => {
    for (const model of CLAUDE_FALLBACK_MODELS) assert.ok(MODEL_PATTERN.test(model.id), model.id);
  });
});
