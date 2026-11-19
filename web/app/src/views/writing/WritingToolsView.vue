<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { CopyDocument, MagicStick, Promotion, Refresh, Setting, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type {
  DrawKind, OptimizePayload, WritingAction, WritingCard, WritingStrength, WritingStyle,
} from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { loadAiSettings, toolsRequestSettings } from './novelSettings';
import {
  ACTION_ITEMS, STRENGTH_OPTIONS, STYLE_OPTIONS, toggleAction,
} from '@/views/writing/options';

type Mode = 'optimize' | 'short' | 'outline';

const MODE_TABS: { key: Mode; label: string; hint: string }[] = [
  { key: 'optimize', label: '自由优化', hint: '贴一段稿子直接改' },
  { key: 'short', label: '短篇抽卡', hint: '抽能直接开写的点子' },
  { key: 'outline', label: '大纲抽卡', hint: '抽长篇骨架' },
];

const mode = ref<Mode>('optimize');
const settingsVisible = ref(false);

/* ── 文稿优化 ── */

const EXAMPLE = [
  '在这个快节奏的时代，时间仿佛被按下了加速键。人们行色匆匆，穿梭于钢筋水泥的丛林之间，追逐着各自的梦想。',
  '不可否认，科技的发展给我们的生活带来了翻天覆地的变化。然而，在享受便利的同时，我们似乎也渐渐失去了某些珍贵的东西。',
  '总之，生活的意义不在于你走了多远，而在于你是否记得为何出发。',
].join('\n\n');

const source = ref('');
const actions = ref<WritingAction[]>(['polish', 'deai']);
const style = ref<WritingStyle>('original');
const strength = ref<WritingStrength>('medium');
const extra = ref('');

const result = ref('');
const streaming = ref(false);
const elapsed = ref<number | null>(null);

let controller: AbortController | null = null;

const sourceChars = computed(() => source.value.length);
const resultChars = computed(() => result.value.length);
const structureOnly = computed(() => actions.value.length === 1 && actions.value[0] === 'structure');
const continueOnly = computed(() => actions.value.length === 1 && actions.value[0] === 'continue');
const showApply = computed(() => !structureOnly.value);
const applyLabel = computed(() => (continueOnly.value ? '追加到原文' : '替换原文'));

function toggleActionKey(key: WritingAction) {
  actions.value = toggleAction(actions.value, key);
}

async function optimize() {
  if (streaming.value) return;
  if (!source.value.trim()) {
    ElMessage.warning('先把要优化的文稿贴进来');
    return;
  }
  if (!actions.value.length) {
    ElMessage.warning('至少选择一个优化动作');
    return;
  }

  const payload: OptimizePayload = {
    text: source.value,
    actions: actions.value,
    style: style.value,
    strength: strength.value,
    extra: extra.value.trim() || undefined,
    settings: toolsRequestSettings(),
  };

  result.value = '';
  elapsed.value = null;
  streaming.value = true;
  controller = new AbortController();
  const startedAt = Date.now();

  try {
    await api.writing.optimize(
      payload,
      {
        onDelta: (delta) => {
          result.value += delta;
        },
        onDone: (info) => {
          elapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt);
        },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止生成，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    streaming.value = false;
    controller = null;
  }
}

function stop() {
  controller?.abort();
}

function fillExample() {
  source.value = EXAMPLE;
}

function applyResult() {
  if (!result.value) return;
  source.value = continueOnly.value
    ? source.value.trimEnd() + '\n\n' + result.value
    : result.value;
  ElMessage.success(continueOnly.value ? '已追加到原文末尾' : '已用优化结果替换原文');
}

async function copy(text: string, label = '已复制到剪贴板') {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    ElMessage.success(label);
  } catch {
    ElMessage.warning('浏览器没有允许复制，请手动选中文本');
  }
}

/* ── 抽卡 ── */

const GENRES = ['都市', '玄幻', '悬疑', '科幻', '历史', '言情', '无限流', '规则怪谈', '克苏鲁', '职场'];
const PERSPECTIVES = ['第三人称', '第一人称', '双视角'];

const genre = ref('都市');
const keywords = ref('');
const perspective = ref('第三人称');
const count = ref(3);
const drawExtra = ref('');

const drawing = ref(false);
const cards = ref<WritingCard[]>([]);
const cardsKind = ref<DrawKind>('short');

const CARD_STORAGE_KEY = 'deepseekapp.writing.cards.v1';
const currentKind = computed<DrawKind>(() => (mode.value === 'outline' ? 'outline' : 'short'));
const drawLabel = computed(() => {
  if (drawing.value) return '正在抽卡…';
  return cards.value.length ? '再抽一组' : '抽一组';
});

async function draw() {
  if (drawing.value) return;
  drawing.value = true;
  try {
    const res = await api.writing.draw({
      kind: currentKind.value,
      genre: genre.value,
      keywords: keywords.value,
      perspective: perspective.value,
      count: count.value,
      extra: drawExtra.value.trim() || undefined,
      settings: toolsRequestSettings(),
    });
    cards.value = res.cards;
    cardsKind.value = res.kind;
    persistCards();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    drawing.value = false;
  }
}

function persistCards() {
  try {
    localStorage.setItem(CARD_STORAGE_KEY, JSON.stringify({ kind: cardsKind.value, cards: cards.value }));
  } catch {
    /* 隐私模式等场景写入失败，忽略即可 */
  }
}

function clearCards() {
  cards.value = [];
  persistCards();
}

function cardText(card: WritingCard): string {
  return [
    card.title,
    card.logline,
    ...card.fields.map((field) => field.label + '：' + field.value),
  ]
    .filter(Boolean)
    .join('\n');
}

onMounted(() => {
  void loadAiSettings();
  try {
    const raw = localStorage.getItem(CARD_STORAGE_KEY);
    if (!raw) return;
    const saved = JSON.parse(raw) as { kind?: DrawKind; cards?: WritingCard[] };
    if (Array.isArray(saved.cards)) {
      cards.value = saved.cards;
      cardsKind.value = saved.kind === 'outline' ? 'outline' : 'short';
    }
  } catch {
    /* 存的内容坏了就当作没有 */
  }
});
</script>

<template>
  <div class="page">
    <PageHeader
      title="写作工具"
      desc="贴一段稿子交给 AI 改写，或抽短篇点子 / 长篇骨架。"
      back="/writing"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
      </template>
    </PageHeader>

    <div class="mode-switch">
      <button
        v-for="tab in MODE_TABS"
        :key="tab.key"
        type="button"
        class="mode-tab"
        :class="{ on: mode === tab.key }"
        @click="mode = tab.key"
      >
        <span class="mode-label">{{ tab.label }}</span>
        <span class="mode-hint">{{ tab.hint }}</span>
      </button>
    </div>

    <!-- 文稿优化 -->
    <div v-show="mode === 'optimize'" class="opt-grid">
      <section class="card card-flush">
        <div class="card-head">
          <h3>原文</h3>
          <span class="mono text-muted">{{ sourceChars }} 字</span>
        </div>
        <div class="card-body">
          <el-input
            v-model="source"
            type="textarea"
            :rows="14"
            resize="vertical"
            placeholder="把要优化的稿子贴在这里，短篇、小事件、文案都可以。"
            class="src-input"
          />
          <div class="src-foot">
            <button type="button" class="link-btn" @click="fillExample">用示例试试</button>
            <button type="button" class="link-btn" @click="source = ''">清空</button>
          </div>

          <div class="field-label">优化动作</div>
          <div class="chips">
            <button
              v-for="item in ACTION_ITEMS"
              :key="item.key"
              type="button"
              class="chip"
              :class="{ on: actions.includes(item.key) }"
              :title="item.hint"
              @click="toggleActionKey(item.key)"
            >
              {{ item.label }}
            </button>
          </div>
          <p class="field-note">{{ structureOnly ? '结构建议只输出诊断与改法，不改写正文。' : '扩写与精简互斥；可多选组合。' }}</p>

          <div class="field-label">风格</div>
          <div class="chips">
            <button
              v-for="item in STYLE_OPTIONS"
              :key="item.key"
              type="button"
              class="chip chip-sm"
              :class="{ on: style === item.key }"
              @click="style = item.key"
            >
              {{ item.label }}
            </button>
          </div>

          <div class="field-label">改动幅度</div>
          <div class="chips">
            <button
              v-for="item in STRENGTH_OPTIONS"
              :key="item.key"
              type="button"
              class="chip chip-sm"
              :class="{ on: strength === item.key }"
              @click="strength = item.key"
            >
              {{ item.label }}
            </button>
          </div>

          <div class="field-label">额外要求（可选）</div>
          <el-input v-model="extra" placeholder="例如：删掉所有比喻，保留人物对话" />

          <div class="run-row">
            <el-button
              v-if="!streaming"
              type="primary"
              size="large"
              :icon="MagicStick"
              @click="optimize"
            >
              开始优化
            </el-button>
            <el-button v-else type="danger" size="large" plain :icon="VideoPause" @click="stop">
              停止
            </el-button>
            <span class="text-muted run-hint">结果边生成边显示，可随时停止</span>
          </div>
        </div>
      </section>

      <section class="card card-flush result-card">
        <div class="card-head">
          <h3>优化结果</h3>
          <span class="result-meta">
            <template v-if="streaming">生成中…</template>
            <template v-else-if="resultChars">
              {{ resultChars }} 字<template v-if="elapsed"> · {{ (elapsed / 1000).toFixed(1) }}s</template>
            </template>
            <template v-else>等待生成</template>
          </span>
        </div>
        <div class="result-body">
          <div v-if="!result && !streaming" class="empty-hint">
            左侧填好文稿、选好动作，点「开始优化」。
          </div>
          <div v-else class="result-text">{{ result }}<span v-if="streaming" class="caret" /></div>
        </div>
        <div v-if="result" class="card-foot">
          <div class="row-gap">
            <el-button :icon="CopyDocument" @click="copy(result)">复制结果</el-button>
            <el-button v-if="showApply" @click="applyResult">{{ applyLabel }}</el-button>
          </div>
          <el-button text :icon="Refresh" :disabled="streaming" @click="optimize">重新生成</el-button>
        </div>
      </section>
    </div>

    <!-- 抽卡 -->
    <div v-show="mode !== 'optimize'" class="draw-grid">
      <section class="card">
        <div class="card-head">
          <h3>{{ currentKind === 'outline' ? '大纲骨架抽卡' : '短篇点子抽卡' }}</h3>
          <span class="mono text-muted">{{ count }} 组</span>
        </div>
        <div class="card-body">
          <el-form label-position="top" class="draw-form">
            <el-form-item label="题材">
              <el-select
                v-model="genre"
                filterable
                allow-create
                default-first-option
                placeholder="选择或直接输入题材"
              >
                <el-option v-for="item in GENRES" :key="item" :label="item" :value="item" />
              </el-select>
            </el-form-item>

            <el-form-item label="关键词 / 梗">
              <el-input
                v-model="keywords"
                type="textarea"
                :rows="2"
                placeholder="重生、职场、反套路、马甲……用顿号或换行分隔"
              />
            </el-form-item>

            <el-form-item label="视角">
              <div class="chips">
                <button
                  v-for="item in PERSPECTIVES"
                  :key="item"
                  type="button"
                  class="chip chip-sm"
                  :class="{ on: perspective === item }"
                  @click="perspective = item"
                >
                  {{ item }}
                </button>
              </div>
            </el-form-item>

            <el-form-item :label="'数量：' + count + ' 组'">
              <el-slider v-model="count" :min="1" :max="5" :step="1" show-stops />
            </el-form-item>

            <el-form-item label="额外要求（可选）">
              <el-input v-model="drawExtra" placeholder="例如：女主视角，不要系统流" />
            </el-form-item>
          </el-form>

          <el-button
            type="primary"
            size="large"
            class="draw-btn"
            :loading="drawing"
            :icon="Promotion"
            @click="draw"
          >
            {{ drawLabel }}
          </el-button>
          <p class="field-note draw-note">
            每次抽取都会换一批角度；抽到顺眼的直接复制走，或点「再抽一组」继续翻。
          </p>
        </div>
      </section>

      <section class="card-list">
        <div v-if="!cards.length && !drawing" class="card empty-draw">
          <el-icon class="empty-icon"><Promotion /></el-icon>
          <div class="empty-title">还没有卡片</div>
          <div class="empty-desc">
            {{ currentKind === 'outline'
              ? '选好题材和梗，抽几套能支撑长篇的骨架。'
              : '选好题材和梗，抽几个能直接开写的短篇点子。' }}
          </div>
        </div>

        <div v-if="drawing" class="idea-card is-loading">
          <el-skeleton :rows="5" animated />
        </div>

        <article v-for="(card, index) in cards" :key="index" class="idea-card">
          <div class="idea-head">
            <span class="idea-index">{{ index + 1 }}</span>
            <span class="idea-title">{{ card.title }}</span>
            <button type="button" class="link-btn idea-copy" @click="copy(cardText(card), '已复制这张卡')">
              复制
            </button>
          </div>
          <p v-if="card.logline" class="idea-logline">{{ card.logline }}</p>
          <div v-if="card.fields.length" class="idea-fields">
            <div v-for="field in card.fields" :key="field.label" class="idea-field">
              <div class="idea-field-label">{{ field.label }}</div>
              <div class="idea-field-value">{{ field.value }}</div>
            </div>
          </div>
        </article>

        <div v-if="cards.length && !drawing" class="list-foot">
          <span class="text-muted">
            最近一次抽取：{{ cardsKind === 'outline' ? '大纲骨架' : '短篇点子' }}
          </span>
          <button type="button" class="link-btn" @click="clearCards">清空</button>
        </div>
      </section>
    </div>

    <AiSettingsDrawer v-model="settingsVisible" kind="tools" />
  </div>
</template>

<style scoped>
/* ── 模式切换 ── */
.mode-switch {
  display: inline-flex;
  gap: 4px;
  padding: 4px;
  border-radius: 12px;
  background: var(--bg-card);
  box-shadow: var(--shadow-1);
  border: 1px solid var(--line);
  margin-bottom: 18px;
}

.mode-tab {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 1px;
  padding: 8px 16px;
  border: none;
  border-radius: 9px;
  background: transparent;
  cursor: pointer;
  text-align: left;
  transition: background 0.15s ease;
}

.mode-tab:hover { background: var(--bg-soft); }
.mode-tab.on { background: var(--brand-soft); }

.mode-label {
  font-size: 13.5px;
  font-weight: 600;
  color: var(--ink-2);
}

.mode-tab.on .mode-label { color: var(--brand); }

.mode-hint {
  font-size: 10.5px;
  color: var(--ink-4);
}

.mode-tab.on .mode-hint { color: var(--ink-3); }

/* ── 文稿优化 ── */
.opt-grid {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .opt-grid { grid-template-columns: minmax(0, 1fr); }
}

.src-input :deep(.el-textarea__inner) {
  font-size: 14px;
  line-height: 1.8;
  padding: 14px 16px;
  background: var(--bg-soft);
  box-shadow: 0 0 0 1px var(--line) inset;
}

.src-foot {
  display: flex;
  justify-content: flex-end;
  gap: 14px;
  margin: 8px 0 18px;
}

.link-btn {
  border: none;
  background: transparent;
  padding: 0;
  font-size: 12.5px;
  color: var(--brand);
  cursor: pointer;
  font-weight: 500;
}

.link-btn:hover { color: var(--brand-dark); text-decoration: underline; }

.field-label {
  margin: 16px 0 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.3px;
  color: var(--ink-3);
}

.field-note {
  margin: 8px 0 0;
  font-size: 11.5px;
  color: var(--ink-4);
  line-height: 1.6;
}

.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.chip {
  padding: 6px 13px;
  border-radius: 999px;
  border: 1px solid var(--line-strong);
  background: var(--bg-card);
  font-size: 12.5px;
  color: var(--ink-2);
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease, color 0.15s ease;
}

.chip:hover { border-color: var(--line-strong); }

.chip.on {
  border-color: var(--line-strong);
  background: var(--brand-soft);
  color: var(--brand);
  font-weight: 600;
}

.chip-sm { padding: 5px 11px; font-size: 12px; }

.run-row {
  display: flex;
  align-items: center;
  gap: 14px;
  margin-top: 22px;
}

.run-hint { font-size: 12px; }

.result-card { display: flex; flex-direction: column; }

.result-meta {
  font-size: 12px;
  color: var(--ink-3);
  font-variant-numeric: tabular-nums;
}

.result-body {
  padding: 20px 22px;
  min-height: 460px;
  flex: 1;
}

.result-text {
  white-space: pre-wrap;
  word-break: break-word;
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 15px;
  line-height: 1.95;
  color: var(--ink-1);
}

.caret {
  display: inline-block;
  width: 7px;
  height: 16px;
  margin-left: 2px;
  vertical-align: -2px;
  border-radius: 1px;
  background: var(--brand);
  animation: blink 1s steps(2, start) infinite;
}

@keyframes blink { to { opacity: 0; } }

/* ── 抽卡 ── */
.draw-grid {
  display: grid;
  grid-template-columns: 340px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .draw-grid { grid-template-columns: minmax(0, 1fr); }
}

.draw-form :deep(.el-form-item) { margin-bottom: 14px; }
.draw-form :deep(.el-form-item__label) { padding-bottom: 4px; font-size: 12px; color: var(--ink-3); }

.draw-btn { width: 100%; margin-top: 4px; }
.draw-note { margin-top: 10px; }

.card-list { display: flex; flex-direction: column; gap: 14px; }

.empty-draw {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 320px;
  text-align: center;
}

.empty-icon { font-size: 30px; color: var(--ink-4); }
.empty-title { font-size: 14px; font-weight: 600; color: var(--ink-2); }
.empty-desc { font-size: 12.5px; color: var(--ink-3); }

.idea-card {
  background: var(--bg-card);
  border-radius: var(--r-lg);
  box-shadow: var(--shadow-2);
  padding: 18px 20px;
}

.idea-card.is-loading { padding: 22px 20px; }

.idea-head {
  display: flex;
  align-items: center;
  gap: 10px;
}

.idea-index {
  width: 24px;
  height: 24px;
  flex: 0 0 24px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  background: var(--brand-soft);
  color: var(--brand);
  font-size: 12px;
  font-weight: 700;
}

.idea-title {
  font-size: 16px;
  font-weight: 650;
  color: var(--ink-1);
  letter-spacing: -0.2px;
}

.idea-copy { margin-left: auto; }

.idea-logline {
  margin: 9px 0 0;
  font-size: 13.5px;
  line-height: 1.7;
  color: var(--ink-2);
}

.idea-fields {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px 20px;
  margin-top: 14px;
  padding-top: 14px;
  border-top: 1px solid var(--line);
}

@media (max-width: 760px) {
  .idea-fields { grid-template-columns: minmax(0, 1fr); }
}

.idea-field-label {
  margin-bottom: 3px;
  font-size: 10.5px;
  font-weight: 600;
  letter-spacing: 0.5px;
  color: var(--ink-4);
}

.idea-field-value {
  font-size: 13px;
  line-height: 1.75;
  color: var(--ink-1);
  white-space: pre-wrap;
  word-break: break-word;
}

.list-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 2px 4px;
  font-size: 12px;
}
</style>
