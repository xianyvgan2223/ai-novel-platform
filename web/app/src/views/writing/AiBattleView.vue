<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { CopyDocument, Delete, MagicStick, Refresh, Setting, VideoPause } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import AiSettingsDrawer from './AiSettingsDrawer.vue';
import { battleRequestSettings, loadAiSettings } from './novelSettings';

const skills = ref('');
const scene = ref('');
const result = ref('');
const extra = ref('');
const aiResult = ref('');
const running = ref(false);
const elapsed = ref<number | null>(null);
const settingsVisible = ref(false);
const saving = ref(false);
const history = ref<Row[]>([]);
const loadingHistory = ref(false);
const undoSnapshot = ref<string | null>(null);
const continueInstruction = ref('');
let controller: AbortController | null = null;

const userInput = computed(() => {
  const parts: string[] = [];
  if (skills.value.trim()) parts.push(`【双方人物技能】${skills.value.trim()}`);
  if (scene.value.trim()) parts.push(`【战斗场景】${scene.value.trim()}`);
  if (result.value.trim()) parts.push(`【战斗结果】${result.value.trim()}`);
  return parts.join('\n');
});

async function generate() {
  if (running.value) return;
  if (!userInput.value) {
    ElMessage.warning('至少填写一项战斗要素（双方技能 / 场景 / 结果）');
    return;
  }
  aiResult.value = '';
  elapsed.value = null;
  running.value = true;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.novel.generateBattle(
      {
        skills: skills.value.trim() || undefined,
        scene: scene.value.trim() || undefined,
        result: result.value.trim() || undefined,
        extra: extra.value.trim() || undefined,
        settings: battleRequestSettings(),
      },
      {
        onDelta: (delta) => { aiResult.value += delta; },
        onDone: (info) => { elapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    running.value = false;
    controller = null;
  }
}

/** 对当前结果继续提要求：把结果作为初稿再让 AI 按新要求重写 */
async function continueGenerate() {
  if (running.value || !aiResult.value) return;
  const instruction = continueInstruction.value.trim();
  if (!instruction) {
    ElMessage.warning('先写一句对结果的要求');
    return;
  }
  const base = aiResult.value;
  undoSnapshot.value = aiResult.value;
  aiResult.value = '';
  running.value = true;
  elapsed.value = null;
  controller = new AbortController();
  const startedAt = Date.now();
  try {
    await api.writing.novel.generateBattle(
      {
        skills: `${skills.value.trim()}\n\n【已有初稿，请按新要求改写】\n${base}`,
        scene: scene.value.trim() || undefined,
        result: result.value.trim() || undefined,
        extra: instruction,
        settings: battleRequestSettings(),
      },
      {
        onDelta: (delta) => { aiResult.value += delta; },
        onDone: (info) => { elapsed.value = Number(info.elapsedMs ?? Date.now() - startedAt); },
      },
      controller.signal,
    );
    continueInstruction.value = '';
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      ElMessage.info('已停止，保留当前结果');
    } else {
      ElMessage.error(err instanceof Error ? err.message : String(err));
    }
  } finally {
    running.value = false;
    controller = null;
  }
}

function undoResult() {
  if (undoSnapshot.value === null) return;
  aiResult.value = undoSnapshot.value;
  undoSnapshot.value = null;
  ElMessage.success('已撤回上一次改写');
}

function stop() {
  controller?.abort();
}

async function copy(text: string) {
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    ElMessage.success('已复制');
  } catch {
    ElMessage.warning('浏览器没有允许复制');
  }
}

async function saveToHistory() {
  if (!aiResult.value.trim()) {
    ElMessage.warning('还没有生成内容');
    return;
  }
  saving.value = true;
  try {
    await api.createRow('deepseek', 'battle_scenes', {
      user_input: userInput.value,
      ai_result: aiResult.value,
      character_skills: skills.value.trim(),
      battle_scene_desc: scene.value.trim(),
      battle_result: result.value.trim(),
      status: 'completed',
      created_at: new Date().toISOString(),
    });
    ElMessage.success('已存进战斗历史');
    await loadHistory();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}

async function loadHistory() {
  loadingHistory.value = true;
  try {
    const res = await api.listRows('deepseek', 'battle_scenes', {
      page: 1,
      pageSize: 50,
      orderBy: 'created_at',
      dir: 'desc',
    });
    history.value = res.data;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loadingHistory.value = false;
  }
}

function loadScene(row: Row) {
  skills.value = String(row.character_skills ?? '');
  scene.value = String(row.battle_scene_desc ?? '');
  result.value = String(row.battle_result ?? '');
  aiResult.value = String(row.ai_result ?? '');
  undoSnapshot.value = null;
  ElMessage.success('已载入到输入框');
}

async function removeScene(row: Row) {
  try {
    await api.deleteRow('deepseek', 'battle_scenes', Number(row.id));
    ElMessage.success('已删除');
    await loadHistory();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

function formatTime(value: unknown): string {
  const text = String(value ?? '');
  if (!text) return '';
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return text;
  return `${date.getMonth() + 1}/${date.getDate()} ${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

onMounted(async () => {
  await loadAiSettings();
  await loadHistory();
});
</script>

<template>
  <div class="page">
    <PageHeader
      title="AI 写战斗"
      desc="填双方技能、场景与结果，AI 直接写出一段完整的战斗场面；可继续提要求、撤回或存进战斗历史。"
      back="/writing"
    >
      <template #actions>
        <el-button :icon="Setting" @click="settingsVisible = true">AI 设置</el-button>
        <el-button :icon="Refresh" :loading="loadingHistory" @click="loadHistory">刷新历史</el-button>
      </template>
    </PageHeader>

    <div class="battle-grid">
      <section class="card card-flush">
        <div class="card-head"><h3>战斗要素</h3></div>
        <div class="pad">
          <div class="field-label">双方人物技能</div>
          <el-input v-model="skills" type="textarea" :rows="2" placeholder="例如：张三的火焰刀、李四的冰霜剑" />

          <div class="field-label">战斗场景</div>
          <el-input v-model="scene" type="textarea" :rows="2" placeholder="例如：雪山之巅、暴雨中的古城" />

          <div class="field-label">战斗结果</div>
          <el-input v-model="result" type="textarea" :rows="2" placeholder="例如：张三以微弱优势获胜" />

          <div class="field-label">额外要求（可选）</div>
          <el-input v-model="extra" placeholder="例如：多写环境描写，少用比喻" />

          <div class="run-row">
            <el-button v-if="!running" type="primary" :icon="MagicStick" @click="generate">
              生成战斗场景
            </el-button>
            <el-button v-else type="danger" plain :icon="VideoPause" @click="stop">停止生成</el-button>
            <span class="hint">1000-3000 字，纯文本。</span>
          </div>
        </div>
      </section>

      <section class="card card-flush">
        <div class="card-head">
          <h3>生成内容</h3>
          <span class="mono text-muted">
            {{ running ? '生成中…' : `${aiResult.length} 字` }}
            <template v-if="!running && elapsed"> · {{ (elapsed / 1000).toFixed(1) }}s</template>
          </span>
        </div>
        <div class="pad">
          <div v-if="!aiResult && !running" class="empty-hint">填写左侧要素后点「生成战斗场景」。</div>
          <div class="result-text">{{ aiResult }}<span v-if="running" class="caret" /></div>
          <div class="continue-row">
            <el-input v-model="continueInstruction" size="small" placeholder="对结果继续提要求，例如：再加一段心理描写" />
            <el-button size="small" :disabled="running || !aiResult" @click="continueGenerate">继续改写</el-button>
          </div>
          <div class="foot-row">
            <div class="row-gap">
              <el-button :icon="CopyDocument" :disabled="!aiResult" @click="copy(aiResult)">复制</el-button>
              <el-button v-if="undoSnapshot !== null" text @click="undoResult">撤回</el-button>
              <el-button type="primary" :loading="saving" :disabled="running || !aiResult" @click="saveToHistory">
                存进战斗历史
              </el-button>
            </div>
            <el-button text :icon="Refresh" :disabled="running" @click="generate">重新生成</el-button>
          </div>
        </div>
      </section>
    </div>

    <section class="card card-flush history-card">
      <div class="card-head">
        <h3>战斗历史</h3>
        <span class="mono text-muted">{{ history.length }} 条</span>
      </div>
      <div v-if="!history.length" class="empty-hint pad">还没有历史记录，生成后可「存进战斗历史」。</div>
      <div v-else class="history-list">
        <div v-for="row in history" :key="String(row.id)" class="history-item">
          <div class="hi-head">
            <span class="hi-time mono">{{ formatTime(row.created_at) }}</span>
            <div class="hi-actions">
              <el-button size="small" text @click="loadScene(row)">载入</el-button>
              <el-button size="small" text :icon="Delete" @click="removeScene(row)">删除</el-button>
            </div>
          </div>
          <div class="hi-input">{{ String(row.user_input ?? '') }}</div>
          <div class="hi-result">{{ String(row.ai_result ?? '') }}</div>
        </div>
      </div>
    </section>

    <AiSettingsDrawer v-model="settingsVisible" kind="battle" />
  </div>
</template>

<style scoped>
.battle-grid {
  display: grid;
  grid-template-columns: 360px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .battle-grid { grid-template-columns: minmax(0, 1fr); }
}

.pad { padding: 16px 18px 18px; }

.field-label { margin: 12px 0 8px; font-size: 12px; font-weight: 600; color: var(--ink-3); }
.field-label:first-child { margin-top: 0; }

.run-row { display: flex; align-items: center; gap: 12px; margin-top: 16px; }
.hint { font-size: 11.5px; color: var(--ink-4); }

.result-text {
  min-height: 300px;
  max-height: 420px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 14.5px;
  line-height: 1.9;
  color: var(--ink-1);
}

.continue-row { display: flex; gap: 8px; margin-top: 12px; }
.foot-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 12px; }
.row-gap { display: flex; align-items: center; gap: 8px; }

.history-card { margin-top: 18px; }
.history-list { display: flex; flex-direction: column; gap: 10px; padding: 14px 16px 18px; }

.history-item {
  padding: 10px 12px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--bg-soft);
}

.hi-head { display: flex; align-items: center; justify-content: space-between; }
.hi-time { font-size: 11px; color: var(--ink-4); }
.hi-actions { display: flex; gap: 2px; }

.hi-input { margin-top: 4px; font-size: 12px; color: var(--ink-3); white-space: pre-wrap; }

.hi-result {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px dashed var(--line);
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--ink-2);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.caret {
  display: inline-block;
  width: 7px;
  height: 15px;
  margin-left: 2px;
  vertical-align: -2px;
  background: var(--brand);
  animation: blink 1s steps(2, start) infinite;
}

@keyframes blink { to { opacity: 0; } }
</style>
