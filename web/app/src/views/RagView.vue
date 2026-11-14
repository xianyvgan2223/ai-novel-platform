<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { ElMessage } from 'element-plus';
import {
  Collection, CopyDocument, Document, MagicStick, Refresh, Search, UploadFilled,
} from '@element-plus/icons-vue';
import { api, formatTime } from '@/api';
import type { RagJob, RagScene, RagStatus } from '@/api';
import PageHeader from '@/components/PageHeader.vue';

const status = ref<RagStatus | null>(null);
const statusLoading = ref(false);

const fileInput = ref<HTMLInputElement | null>(null);
const selectedFile = ref<File | null>(null);
const bookTitle = ref('');
const importing = ref(false);
const job = ref<RagJob | null>(null);
let pollTimer: number | undefined;

const query = ref('');
const tagInput = ref('');
const style = ref('');
const extra = ref('');
const searching = ref(false);
const hits = ref<RagScene[]>([]);
const imitating = ref(false);
const draft = ref('');
const references = ref<RagScene[]>([]);

const scenes = ref<RagScene[]>([]);
const scenesLoading = ref(false);
const sceneQuery = ref('');
const page = ref(1);
const pageSize = ref(9);
const total = ref(0);

const hasStatus = computed(() => status.value != null);
const ragReady = computed(() => status.value?.esOnline && status.value?.embeddingConfigured);
const tagOptions = computed(() => status.value?.tags ?? []);

function handleFile(event: Event) {
  const input = event.target as HTMLInputElement;
  selectedFile.value = input.files?.[0] ?? null;
  if (!selectedFile.value) return;
  const name = selectedFile.value.name.replace(/\.txt$/i, '');
  if (!bookTitle.value.trim()) bookTitle.value = name;
}

function pickFile() {
  fileInput.value?.click();
}

function clearFile() {
  selectedFile.value = null;
  if (fileInput.value) fileInput.value.value = '';
}

async function loadStatus() {
  statusLoading.value = true;
  try {
    status.value = await api.rag.status();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    statusLoading.value = false;
  }
}

async function loadScenes() {
  scenesLoading.value = true;
  try {
    const res = await api.rag.scenes({
      page: page.value,
      pageSize: pageSize.value,
      q: sceneQuery.value.trim(),
    });
    scenes.value = res.data;
    total.value = Number(res.meta.total ?? 0);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    scenesLoading.value = false;
  }
}

async function startImport() {
  if (!selectedFile.value) {
    ElMessage.warning('先选择一部小说 .txt 文件');
    return;
  }
  importing.value = true;
  job.value = null;
  try {
    const res = await api.rag.importNovel(selectedFile.value, bookTitle.value.trim());
    ElMessage.success(`已开始解析《${res.book}》，共 ${res.chars.toLocaleString()} 字`);
    await pollJob(res.jobId);
    await loadStatus();
    page.value = 1;
    await loadScenes();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    importing.value = false;
  }
}

async function pollJob(id: string) {
  return new Promise<void>((resolve) => {
    const tick = async () => {
      try {
        const next = await api.rag.job(id);
        job.value = next;
        if (next.status === 'done') {
          ElMessage.success(next.message || '导入完成');
          resolve();
          return;
        }
        if (next.status === 'failed') {
          ElMessage.error(next.error || '导入失败');
          resolve();
          return;
        }
      } catch (err) {
        ElMessage.error(err instanceof Error ? err.message : String(err));
        resolve();
        return;
      }
      pollTimer = window.setTimeout(tick, 1500);
    };
    void tick();
  });
}

function parseTags(raw: string): string[] {
  return raw
    .split(/[,，、\s]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

async function search() {
  if (!query.value.trim()) {
    ElMessage.warning('请输入想找的情节描述');
    return;
  }
  searching.value = true;
  try {
    const res = await api.rag.search({
      query: query.value.trim(),
      size: 8,
      tags: parseTags(tagInput.value),
    });
    hits.value = res.hits;
    if (!hits.value.length) ElMessage.warning('没有检索到匹配情节');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    searching.value = false;
  }
}

async function imitate() {
  if (!query.value.trim()) {
    ElMessage.warning('请先写一句想写的剧情方向');
    return;
  }
  imitating.value = true;
  draft.value = '';
  references.value = [];
  try {
    const res = await api.rag.imitate({
      query: query.value.trim(),
      size: 4,
      tags: parseTags(tagInput.value),
      style: style.value.trim(),
      extra: extra.value.trim(),
    });
    draft.value = res.draft;
    references.value = res.references;
    ElMessage.success('仿写完成');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    imitating.value = false;
  }
}

async function copyDraft() {
  if (!draft.value) return;
  try {
    await navigator.clipboard.writeText(draft.value);
    ElMessage.success('已复制');
  } catch {
    ElMessage.warning('复制失败，请手动选择文本');
  }
}

function useTag(tag: string) {
  tagInput.value = tag;
  void search();
}

function searchScenes() {
  page.value = 1;
  void loadScenes();
}

function resetDraft() {
  draft.value = '';
  references.value = [];
}

let searchTimer: number | undefined;
function onSceneSearchInput() {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    page.value = 1;
    void loadScenes();
  }, 350);
}

onMounted(async () => {
  await Promise.all([loadStatus(), loadScenes()]);
});
onUnmounted(() => {
  window.clearTimeout(pollTimer);
  window.clearTimeout(searchTimer);
});
</script>

<template>
  <div class="page rag-page">
    <PageHeader title="情节素材库" desc="导入小说 txt，用 DeepSeek 拆出可复用情节，向量检索后仿写新桥段。">
      <template #actions>
        <el-button :icon="Refresh" :loading="statusLoading" @click="loadStatus">刷新状态</el-button>
      </template>
    </PageHeader>

    <div class="rag-stats">
      <div class="rag-stat">
        <span class="rag-stat-label">已入库情节</span>
        <strong>{{ status?.totalScenes ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">来源作品</span>
        <strong>{{ status?.totalBooks ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">情节标签</span>
        <strong>{{ status?.tags?.length ?? 0 }}</strong>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">向量库</span>
        <span class="rag-conn" :class="status?.esOnline ? 'on' : 'off'">
          <i />{{ status?.esOnline ? 'Elasticsearch 在线' : 'Elasticsearch 未连接' }}
        </span>
      </div>
      <div class="rag-stat">
        <span class="rag-stat-label">Embedding</span>
        <span class="rag-conn" :class="status?.embeddingConfigured ? 'on' : 'off'">
          <i />{{ status?.embeddingConfigured ? status?.embeddingModel : '未配置百炼 Key' }}
        </span>
      </div>
    </div>

    <el-alert
      v-if="hasStatus && !ragReady"
      type="warning"
      :closable="false"
      show-icon
      class="rag-alert"
      title="RAG 还没有完全就绪"
      :description="status?.error || '请检查 Elasticsearch 与 DASHSCOPE_API_KEY 配置。'"
    />

    <div class="rag-grid">
      <section class="card rag-panel">
        <div class="panel-head">
          <div>
            <h3>导入小说</h3>
            <p>DeepSeek 按情节拆段，百炼生成 embedding，写入向量库。</p>
          </div>
          <el-icon class="panel-icon"><UploadFilled /></el-icon>
        </div>

        <input ref="fileInput" type="file" accept=".txt,text/plain" hidden @change="handleFile" />
        <button class="drop-zone" type="button" :class="{ filled: selectedFile }" @click="pickFile">
          <el-icon><Document /></el-icon>
          <template v-if="selectedFile">
            <span class="drop-title">{{ selectedFile.name }}</span>
            <span class="drop-hint">{{ (selectedFile.size / 1024 / 1024).toFixed(2) }} MB · 点击更换</span>
          </template>
          <template v-else>
            <span class="drop-title">选择小说 txt</span>
            <span class="drop-hint">支持 UTF-8 / GB18030，单次最多 200 万字</span>
          </template>
        </button>

        <div class="import-row">
          <el-input v-model="bookTitle" placeholder="作品名（留空取文件名）" clearable />
          <el-button v-if="selectedFile" text @click="clearFile">清除</el-button>
        </div>

        <div class="panel-actions">
          <el-button
            type="primary"
            :icon="MagicStick"
            :loading="importing"
            :disabled="!selectedFile || !ragReady"
            @click="startImport"
          >
            解析并入库
          </el-button>
          <span class="panel-hint">会覆盖同名的旧素材</span>
        </div>

        <div v-if="job" class="job-progress">
          <div class="job-top">
            <span class="job-phase">{{ job.phase }}</span>
            <span class="job-num">{{ job.progress }}%</span>
          </div>
          <el-progress :percentage="job.progress" :show-text="false" :stroke-width="5" color="var(--ink-1)" />
          <div class="job-message">{{ job.message }}</div>
          <div v-if="job.status === 'done'" class="job-done">
            已入库 {{ job.sceneCount }} 个情节，页面下方可直接查看。
          </div>
        </div>

        <div class="steps">
          <div><b>01</b><span>DeepSeek 拆解情节梗概与标签</span></div>
          <div><b>02</b><span>百炼 embedding 生成语义向量</span></div>
          <div><b>03</b><span>Elasticsearch kNN 入库，可检索</span></div>
        </div>
      </section>

      <section class="card rag-panel">
        <div class="panel-head">
          <div>
            <h3>检索与仿写</h3>
            <p>从素材库找结构相近的情节，再生成一段全新的正文。</p>
          </div>
          <el-icon class="panel-icon"><Search /></el-icon>
        </div>

        <el-input
          v-model="query"
          type="textarea"
          :rows="4"
          resize="none"
          placeholder="例如：雨夜，主角独自在废弃小屋，一个陌生人敲门求助，但他怀疑对方另有所图"
        />
        <div class="search-options">
          <el-input v-model="tagInput" placeholder="标签过滤（可选），用逗号分隔" clearable />
          <el-input v-model="style" placeholder="仿写风格（可选）" clearable />
        </div>
        <el-input v-model="extra" placeholder="额外要求（可选），例如：第一人称、结尾留悬念" clearable />

        <div class="panel-actions">
          <el-button :icon="Search" :loading="searching" :disabled="!ragReady" @click="search">检索相关情节</el-button>
          <el-button
            type="primary"
            :icon="MagicStick"
            :loading="imitating"
            :disabled="!ragReady"
            @click="imitate"
          >
            检索并仿写
          </el-button>
        </div>

        <div v-if="tagOptions.length" class="tag-cloud">
          <button v-for="tag in tagOptions.slice(0, 10)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
            {{ tag }}
          </button>
        </div>
      </section>
    </div>

    <section v-if="draft" class="card draft-panel">
      <div class="panel-head">
        <div>
          <h3>仿写结果</h3>
          <p>参考了 {{ references.length }} 条已有情节的结构与情绪曲线。</p>
        </div>
        <div class="draft-actions">
          <el-button text :icon="CopyDocument" @click="copyDraft">复制</el-button>
          <el-button text @click="resetDraft">关闭</el-button>
        </div>
      </div>
      <div class="draft-text">{{ draft }}</div>
      <div class="ref-list">
        <div v-for="(ref, index) in references" :key="ref.id" class="ref-item">
          <span class="ref-index">{{ String(index + 1).padStart(2, '0') }}</span>
          <div class="ref-main">
            <div class="ref-title">{{ ref.title }}</div>
            <div class="ref-tags">
              <span class="tag-chip mini">{{ ref.sceneType || '情节' }}</span>
              <span v-for="tag in ref.tags.slice(0, 3)" :key="tag" class="tag-chip mini">{{ tag }}</span>
            </div>
          </div>
          <span class="ref-score" v-if="ref.score">相似度 {{ (ref.score * 100).toFixed(0) }}</span>
        </div>
      </div>
    </section>

    <section v-if="hits.length" class="card hits-panel">
      <div class="panel-head">
        <div>
          <h3>检索到的情节</h3>
          <p>按语义相似度排序，可作为仿写的结构参考。</p>
        </div>
      </div>
      <div class="scene-grid">
        <article v-for="scene in hits" :key="scene.id" class="scene-card">
          <div class="scene-top">
            <span class="scene-type">{{ scene.sceneType || '情节' }}</span>
            <span class="scene-score" v-if="scene.score">相似度 {{ (scene.score * 100).toFixed(0) }}</span>
          </div>
          <h4>{{ scene.title }}</h4>
          <div class="scene-book">{{ scene.book }}</div>
          <p>{{ scene.plot }}</p>
          <div class="scene-tags">
            <button v-for="tag in scene.tags.slice(0, 4)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
              {{ tag }}
            </button>
          </div>
        </article>
      </div>
    </section>

    <section class="card library-panel">
      <div class="panel-head">
        <div>
          <h3>已入库情节</h3>
          <p>当前向量库共 {{ total }} 条情节素材。</p>
        </div>
        <el-input
          v-model="sceneQuery"
          class="library-search"
          placeholder="搜索标题 / 情节 / 标签"
          clearable
          :prefix-icon="Search"
          @input="onSceneSearchInput"
          @clear="searchScenes"
        />
      </div>

      <div v-loading="scenesLoading" class="scene-grid">
        <article v-for="scene in scenes" :key="scene.id" class="scene-card">
          <div class="scene-top">
            <span class="scene-type">{{ scene.sceneType || '情节' }}</span>
            <span class="scene-book inline">{{ scene.book }}</span>
          </div>
          <h4>{{ scene.title }}</h4>
          <p>{{ scene.plot }}</p>
          <div class="scene-tags">
            <button v-for="tag in scene.tags.slice(0, 4)" :key="tag" type="button" class="tag-chip" @click="useTag(tag)">
              {{ tag }}
            </button>
          </div>
          <div class="scene-foot">
            <span>{{ formatTime(scene.createdAt) }}</span>
            <span>{{ scene.characters.join('、') || '—' }}</span>
          </div>
        </article>
      </div>

      <div v-if="!scenesLoading && !scenes.length" class="empty-hint">
        <el-icon class="empty-icon"><Collection /></el-icon>
        <div>还没有入库情节。先导入一部小说 txt 建立素材库。</div>
      </div>

      <div v-if="total > pageSize" class="library-foot">
        <el-pagination
          v-model:current-page="page"
          v-model:page-size="pageSize"
          :total="total"
          :page-sizes="[9, 18, 36]"
          layout="sizes, prev, pager, next"
          @current-change="loadScenes"
          @size-change="searchScenes"
        />
      </div>
    </section>
  </div>
</template>

<style scoped>
.rag-page { max-width: 1480px; }

.rag-stats {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 1px;
  margin-bottom: 18px;
  border: 1px solid var(--line);
  border-radius: var(--r-lg);
  overflow: hidden;
  background: var(--line);
}

.rag-stat {
  min-height: 86px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 8px;
  padding: 16px 18px;
  background: var(--bg-card);
}

.rag-stat-label {
  font-size: 11.5px;
  color: var(--ink-3);
  letter-spacing: 0.2px;
}

.rag-stat strong {
  font-size: 25px;
  line-height: 1;
  font-weight: 560;
  letter-spacing: -0.8px;
  color: var(--ink-1);
}

.rag-conn {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  font-size: 12px;
  color: var(--ink-2);
  line-height: 1.4;
}
.rag-conn i { width: 6px; height: 6px; border-radius: 50%; background: var(--ink-4); }
.rag-conn.on i { background: var(--ok); }
.rag-conn.off i { background: var(--danger); }

.rag-alert { margin-bottom: 18px; }

.rag-grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 18px;
  margin-bottom: 18px;
}

.rag-panel { margin-bottom: 0; }
.panel-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 14px; margin-bottom: 16px; }
.panel-head h3 { margin: 0; font-size: 16px; font-weight: 600; letter-spacing: 0.1px; }
.panel-head p { margin: 6px 0 0; font-size: 12.5px; line-height: 1.6; color: var(--ink-3); }
.panel-icon { font-size: 20px; color: var(--ink-4); }

.drop-zone {
  width: 100%;
  min-height: 118px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  border: 1px dashed var(--line-strong);
  border-radius: var(--r-md);
  background: var(--bg-soft);
  color: var(--ink-2);
  cursor: pointer;
  transition: border-color 0.16s ease, background 0.16s ease;
}
.drop-zone:hover, .drop-zone.filled { border-color: var(--ink-3); background: var(--bg-card); }
.drop-zone .el-icon { font-size: 24px; color: var(--ink-3); margin-bottom: 2px; }
.drop-title { font-size: 13px; font-weight: 550; color: var(--ink-1); }
.drop-hint { font-size: 11.5px; color: var(--ink-3); }

.import-row { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
.import-row .el-input { flex: 1; }
.panel-actions { display: flex; align-items: center; gap: 12px; margin-top: 14px; flex-wrap: wrap; }
.panel-hint { font-size: 11.5px; color: var(--ink-3); }

.job-progress { margin-top: 16px; padding: 14px; border: 1px solid var(--line); border-radius: var(--r-md); background: var(--bg-soft); }
.job-top { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 12px; color: var(--ink-2); }
.job-phase { font-weight: 550; }
.job-num { font-variant-numeric: tabular-nums; color: var(--ink-3); }
.job-message { margin-top: 8px; font-size: 12px; color: var(--ink-3); line-height: 1.6; }
.job-done { margin-top: 6px; font-size: 12px; color: var(--ok); }

.steps { display: flex; flex-direction: column; gap: 9px; margin-top: 20px; padding-top: 15px; border-top: 1px solid var(--line); }
.steps div { display: flex; gap: 10px; align-items: baseline; font-size: 12px; color: var(--ink-3); }
.steps b { font-family: var(--font-serif); font-size: 13px; color: var(--ink-4); font-weight: 500; }

.search-options { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin: 10px 0; }
.tag-cloud { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 16px; }
.tag-chip {
  border: 1px solid var(--line-strong);
  border-radius: 5px;
  background: transparent;
  color: var(--ink-2);
  padding: 3px 8px;
  font-size: 11px;
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.tag-chip:hover { border-color: var(--ink-3); background: var(--bg-soft); }
.tag-chip.mini { padding: 2px 6px; font-size: 10.5px; }

.draft-panel, .hits-panel, .library-panel { margin-bottom: 18px; }
.draft-actions { display: flex; align-items: center; gap: 4px; }
.draft-text {
  padding: 20px 22px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-soft);
  font-family: var(--font-serif);
  font-size: 14.5px;
  line-height: 1.95;
  color: var(--ink-1);
  white-space: pre-wrap;
}
.ref-list { margin-top: 14px; display: flex; flex-direction: column; gap: 0; }
.ref-item { display: flex; align-items: flex-start; gap: 12px; padding: 11px 2px; border-bottom: 1px solid var(--line); }
.ref-item:last-child { border-bottom: none; }
.ref-index { font-family: var(--font-serif); font-size: 13px; color: var(--ink-4); padding-top: 1px; }
.ref-main { flex: 1; min-width: 0; }
.ref-title { font-size: 13px; font-weight: 550; color: var(--ink-1); }
.ref-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 5px; }
.ref-score { font-size: 11px; color: var(--ink-3); white-space: nowrap; }

.scene-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.scene-card {
  display: flex;
  flex-direction: column;
  min-height: 190px;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: var(--r-md);
  background: var(--bg-card);
}
.scene-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.scene-type { font-size: 10.5px; letter-spacing: 0.4px; color: var(--ink-3); }
.scene-score { font-size: 10.5px; color: var(--ink-3); font-variant-numeric: tabular-nums; }
.scene-book { margin-top: 3px; font-size: 11px; color: var(--ink-3); }
.scene-book.inline { margin-top: 0; max-width: 60%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.scene-card h4 { margin: 7px 0 5px; font-size: 13.5px; font-weight: 600; line-height: 1.5; color: var(--ink-1); }
.scene-card p {
  flex: 1;
  margin: 0;
  display: -webkit-box;
  -webkit-line-clamp: 4;
  line-clamp: 4;
  -webkit-box-orient: vertical;
  overflow: hidden;
  font-size: 12px;
  line-height: 1.75;
  color: var(--ink-2);
}
.scene-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 12px; }
.scene-foot { display: flex; justify-content: space-between; gap: 8px; margin-top: 10px; padding-top: 9px; border-top: 1px solid var(--line); font-size: 10.5px; color: var(--ink-3); }

.library-search { width: 260px; }
.library-foot { display: flex; justify-content: flex-end; margin-top: 16px; }
.empty-hint { display: flex; flex-direction: column; align-items: center; gap: 10px; }
.empty-icon { font-size: 24px; color: var(--ink-4); }

@media (max-width: 1200px) {
  .rag-stats { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .scene-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 900px) {
  .rag-grid { grid-template-columns: minmax(0, 1fr); }
  .rag-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .scene-grid { grid-template-columns: minmax(0, 1fr); }
  .library-search { width: 180px; }
  .search-options { grid-template-columns: minmax(0, 1fr); }
}
</style>
