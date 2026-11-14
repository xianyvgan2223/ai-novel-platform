<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import { Headset, Refresh, VideoPause, VideoPlay } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row } from '@/api';
import PageHeader from '@/components/PageHeader.vue';
import { loadOutlines } from './novelApi';

interface NameCandidate {
  name: string;
  count: number;
  reason: string;
}

const works = ref<Row[]>([]);
const workId = ref<number | null>(null);
const outline = ref<Row | null>(null);
const loading = ref(false);
const content = ref('');

/* ── 朗读 ── */
const supported = typeof window !== 'undefined' && 'speechSynthesis' in window;
const speaking = ref(false);
const paused = ref(false);
const rate = ref(1);
const currentLine = ref(-1);
let segments: { index: number; text: string }[] = [];
let cursor = 0;

const lines = computed(() => content.value.split('\n'));

function buildSegments() {
  segments = [];
  lines.value.forEach((line, index) => {
    const text = line.trim();
    if (text) segments.push({ index, text });
  });
  cursor = 0;
}

function startSpeak() {
  if (!supported) {
    ElMessage.warning('当前浏览器不支持语音朗读');
    return;
  }
  if (!content.value.trim()) {
    ElMessage.warning('这部作品还没有大纲正文');
    return;
  }
  window.speechSynthesis.cancel();
  buildSegments();
  speaking.value = true;
  paused.value = false;
  speakAt(cursor);
}

function speakAt(index: number) {
  if (index >= segments.length) {
    stopSpeak();
    ElMessage.success('已读完');
    return;
  }
  const segment = segments[index];
  currentLine.value = segment.index;
  const utterance = new SpeechSynthesisUtterance(segment.text);
  utterance.lang = 'zh-CN';
  utterance.rate = rate.value;
  utterance.onend = () => {
    if (!speaking.value || paused.value) return;
    cursor = index + 1;
    speakAt(cursor);
  };
  utterance.onerror = () => {
    stopSpeak();
  };
  window.speechSynthesis.speak(utterance);
}

function pauseSpeak() {
  if (!speaking.value) return;
  paused.value = true;
  window.speechSynthesis.pause();
}

function resumeSpeak() {
  if (!speaking.value || !paused.value) return;
  paused.value = false;
  window.speechSynthesis.resume();
}

function stopSpeak() {
  speaking.value = false;
  paused.value = false;
  currentLine.value = -1;
  if (supported) window.speechSynthesis.cancel();
}

watch(rate, () => {
  if (speaking.value && !paused.value) {
    // 语速只能在下一句生效，这里直接重读
    stopSpeak();
    startSpeak();
  }
});

/* ── 改名 ── */
const SURNAMES = '李王张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾萧田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦傅方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤';
const candidates = ref<NameCandidate[]>([]);
const oldName = ref('');
const newName = ref('');
const applying = ref(false);

function countOccurrences(text: string, key: string): number {
  if (!key) return 0;
  let count = 0;
  let at = text.indexOf(key);
  while (at >= 0) {
    count += 1;
    at = text.indexOf(key, at + key.length);
  }
  return count;
}

const hitCount = computed(() => countOccurrences(content.value, oldName.value.trim()));
const fieldHitCount = computed(() => {
  const key = oldName.value.trim();
  if (!key) return 0;
  const row = outline.value;
  if (!row) return 0;
  return ['theme', 'protagonist', 'worldview', 'characters']
    .map((field) => countOccurrences(String(row[field] ?? ''), key))
    .reduce((sum, value) => sum + value, 0);
});

function scanCandidates() {
  const list = new Map<string, NameCandidate>();
  const add = (name: string, reason: string) => {
    const text = name.trim();
    if (text.length < 2 || text.length > 4) return;
    const existing = list.get(text);
    if (existing) {
      existing.count += 1;
    } else {
      list.set(text, { name: text, count: 1, reason });
    }
  };

  const protagonist = String(outline.value?.protagonist ?? '').split(/[、,，/／\s]+/);
  protagonist.forEach((name) => add(name, '小说设定里的主角'));

  const body = content.value;
  const twoChar = new RegExp(`[${SURNAMES}][\\u4e00-\\u9fa5]`, 'g');
  for (const match of body.matchAll(twoChar)) {
    add(match[0], '姓氏开头');
  }

  const placeSuffix = /([\u4e00-\u9fa5]{2}(?:城|山|河|派|宗|门|殿|宫|阁|谷|村|镇|府|朝|国|州))/g;
  for (const match of body.matchAll(placeSuffix)) {
    add(match[1], '地名 / 门派');
  }

  candidates.value = [...list.values()]
    .filter((item) => item.count >= 2 || item.reason.includes('主角'))
    .sort((a, b) => b.count - a.count)
    .slice(0, 40);
}

function pickCandidate(item: NameCandidate) {
  oldName.value = item.name;
}

async function applyRename() {
  const from = oldName.value.trim();
  const to = newName.value.trim();
  if (!from || !to) {
    ElMessage.warning('请填写要替换的旧名与新名');
    return;
  }
  if (from === to) {
    ElMessage.warning('新旧名字相同');
    return;
  }
  if (!hitCount.value && !fieldHitCount.value) {
    ElMessage.warning('大纲正文和小说设定里都没有找到这个名字');
    return;
  }
  if (!outline.value) return;

  applying.value = true;
  try {
    const nextContent = content.value.split(from).join(to);
    const row = outline.value;
    const nextTheme = String(row.theme ?? '').split(from).join(to);
    const nextProtagonist = String(row.protagonist ?? '').split(from).join(to);
    const nextWorldview = String(row.worldview ?? '').split(from).join(to);
    const nextCharacters = String(row.characters ?? '').split(from).join(to);
    await api.updateRow('deepseek', 'outline_records', Number(row.id), {
      content: nextContent,
      theme: nextTheme,
      protagonist: nextProtagonist,
      worldview: nextWorldview,
      characters: nextCharacters,
    });
    content.value = nextContent;
    row.content = nextContent;
    row.theme = nextTheme;
    row.protagonist = nextProtagonist;
    row.worldview = nextWorldview;
    row.characters = nextCharacters;
    ElMessage.success(`已把「${from}」全部替换为「${to}」并保存`);
    oldName.value = '';
    newName.value = '';
    scanCandidates();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    applying.value = false;
  }
}

/* ── 加载 ── */
async function loadWorks() {
  loading.value = true;
  try {
    works.value = await loadOutlines();
    if (!workId.value && works.value.length) {
      workId.value = Number(works.value[0].id);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

async function loadOutline() {
  if (!workId.value) return;
  stopSpeak();
  loading.value = true;
  try {
    const row = await api.getRow('deepseek', 'outline_records', workId.value);
    outline.value = row;
    content.value = String(row.content ?? '');
    oldName.value = '';
    newName.value = '';
    scanCandidates();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

onMounted(async () => {
  await loadWorks();
  await loadOutline();
});

onUnmounted(() => {
  stopSpeak();
});
</script>

<template>
  <div class="page" v-loading="loading">
    <PageHeader
      title="听大纲改名"
      desc="边听 AI 朗读大纲，边把不满意的人名、地名一键替换，改完直接写回当前设备的库。"
      back="/writing"
    >
      <template #actions>
        <el-select v-model="workId" placeholder="选择作品" class="work-select" @change="loadOutline">
          <el-option v-for="item in works" :key="String(item.id)" :label="String(item.title || '未命名')" :value="Number(item.id)" />
        </el-select>
        <el-button :icon="Refresh" @click="loadOutline">刷新</el-button>
      </template>
    </PageHeader>

    <div v-if="!works.length" class="card empty-card">
      还没有作品。先去「一键生成大纲」或「匹配大纲格式」建一部。
    </div>

    <div v-else class="listen-grid">
      <section class="card card-flush">
        <div class="card-head">
          <h3>大纲正文 · {{ String(outline?.title || '') }}</h3>
          <span class="mono text-muted">{{ content.length }} 字</span>
        </div>
        <div class="tts-bar">
          <el-button v-if="!speaking" type="primary" :icon="VideoPlay" @click="startSpeak">开始朗读</el-button>
          <template v-else>
            <el-button v-if="!paused" :icon="VideoPause" @click="pauseSpeak">暂停</el-button>
            <el-button v-else type="primary" :icon="VideoPlay" @click="resumeSpeak">继续</el-button>
            <el-button type="danger" plain @click="stopSpeak">停止</el-button>
          </template>
          <span class="rate-label">语速</span>
          <el-slider v-model="rate" :min="0.5" :max="2" :step="0.1" class="rate-slider" />
          <span class="mono text-muted">{{ rate.toFixed(1) }}x</span>
          <span v-if="!supported" class="warn">当前浏览器不支持语音朗读</span>
        </div>
        <div class="text-body">
          <div
            v-for="(line, index) in lines"
            :key="index"
            class="text-line"
            :class="{ on: currentLine === index }"
          >
            {{ line || '\u00a0' }}
          </div>
        </div>
      </section>

      <section class="card card-flush rename-panel">
        <div class="card-head">
          <h3>改名</h3>
          <span class="mono text-muted">{{ candidates.length }} 个候选</span>
        </div>
        <div class="rename-body">
          <div class="field-label">候选名字（点一下填入旧名）</div>
          <div class="chips">
            <button
              v-for="item in candidates"
              :key="item.name"
              type="button"
              class="chip"
              :class="{ on: oldName === item.name }"
              @click="pickCandidate(item)"
            >
              {{ item.name }} <span class="chip-count">{{ item.count }}</span>
            </button>
            <span v-if="!candidates.length" class="hint">没有自动识别到候选，可以直接手填。</span>
          </div>

          <div class="field-label">旧名</div>
          <el-input v-model="oldName" placeholder="例如：林川" />

          <div class="field-label">新名</div>
          <el-input v-model="newName" placeholder="例如：林寒" />

          <div class="hit-line">
            正文命中 <strong>{{ hitCount }}</strong> 处
            <template v-if="fieldHitCount"> · 小说设定命中 <strong>{{ fieldHitCount }}</strong> 处</template>
          </div>

          <el-button type="primary" :icon="Headset" :loading="applying" @click="applyRename">
            替换并保存
          </el-button>
          <div class="hint block">
            替换会同时改写大纲正文、主题、主角简介、世界观与人物档案；已写小事件正文不会受影响。
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.work-select { width: 200px; }

.empty-card { padding: 28px; text-align: center; color: var(--ink-3); font-size: 13px; }

.listen-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 340px;
  gap: 18px;
  align-items: start;
}

@media (max-width: 1100px) {
  .listen-grid { grid-template-columns: minmax(0, 1fr); }
}

.tts-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--line);
}

.rate-label { margin-left: 8px; font-size: 11.5px; color: var(--ink-3); }
.rate-slider { width: 120px; }
.warn { font-size: 11.5px; color: var(--warn); }

.text-body {
  max-height: calc(100vh - 320px);
  overflow: auto;
  padding: 10px 16px 20px;
}

.text-line {
  padding: 3px 8px;
  border-radius: 6px;
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 13.5px;
  line-height: 1.9;
  color: var(--ink-1);
  white-space: pre-wrap;
}

.text-line.on { background: var(--brand-soft); color: var(--brand); }

.rename-body { padding: 14px 16px 18px; }

.field-label { margin: 12px 0 8px; font-size: 12px; font-weight: 600; color: var(--ink-3); }
.field-label:first-child { margin-top: 0; }

.chips { display: flex; flex-wrap: wrap; gap: 8px; }

.chip {
  padding: 5px 11px;
  border-radius: 999px;
  border: 1px solid var(--line-strong);
  background: var(--bg-card);
  font-size: 12.5px;
  color: var(--ink-2);
  cursor: pointer;
}

.chip.on { border-color: var(--line-strong); background: var(--brand-soft); color: var(--brand); font-weight: 600; }
.chip-count { margin-left: 2px; font-size: 10.5px; color: var(--ink-4); }

.hit-line { margin-top: 12px; font-size: 12.5px; color: var(--ink-3); }
.hit-line strong { color: var(--ink-1); }

.hint { font-size: 11.5px; color: var(--ink-4); line-height: 1.6; }
.hint.block { display: block; margin-top: 10px; }
</style>
