<script setup lang="ts">
/**
 * 「导入大纲 txt」弹窗：选 .txt 文件 → 解码 / 解析 v2 结构化格式（正文 + 小说设定 +
 * 人物档案，兼容旧版纯正文）→ 预览 → 新建作品并写入事件。
 */
import { computed, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { ElMessage } from 'element-plus';
import { Upload } from '@element-plus/icons-vue';
import { api } from '@/api';
import {
  DECODE_ERROR_MESSAGE,
  charactersToDbJson,
  decodeOutlineBytes,
  deriveOutlineTitleFromDocument,
  parseOutlineEvents,
  parseOutlineTxtDocument,
} from './outlineTxtTransfer';
import type { ParsedOutlineDocument, ParsedOutlineEvent } from './outlineTxtTransfer';

const props = defineProps<{ modelValue: boolean }>();
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>();

const router = useRouter();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const fileInput = ref<HTMLInputElement | null>(null);
const document = ref<ParsedOutlineDocument | null>(null);
const fileName = ref('');
const content = ref('');
const title = ref('');
const events = ref<ParsedOutlineEvent[]>([]);
const reading = ref(false);
const importing = ref(false);

const hasFile = computed(() => document.value !== null);
const settingsSummary = computed(() => document.value?.settingsSummary ?? '');
const eventCount = computed(() => events.value.length);
const charCount = computed(() => content.value.length);
const previewLines = computed(() => content.value.split('\n').slice(0, 8));
const hasMorePreview = computed(() => content.value.split('\n').length > previewLines.value.length);

function resetState() {
  document.value = null;
  fileName.value = '';
  content.value = '';
  title.value = '';
  events.value = [];
  reading.value = false;
  importing.value = false;
  if (fileInput.value) fileInput.value.value = '';
}

// 每次打开弹窗重置，避免上一次选的文件残留
watch(
  () => props.modelValue,
  (opened) => {
    if (opened) resetState();
  },
);

function pickFile() {
  if (reading.value || importing.value) return;
  fileInput.value?.click();
}

/** 解码并解析文件内容；用户取消选择文件时不会触发 change，静默返回 */
async function handleFileChange(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (!file) return;
  input.value = ''; // 允许连续选同一个文件
  reading.value = true;
  try {
    const buffer = await file.arrayBuffer();
    let decoded: string;
    try {
      decoded = decodeOutlineBytes(new Uint8Array(buffer));
    } catch (err) {
      ElMessage.error(err instanceof Error ? err.message : DECODE_ERROR_MESSAGE);
      return;
    }
    let parsed: ParsedOutlineDocument;
    try {
      parsed = parseOutlineTxtDocument(decoded);
    } catch (err) {
      ElMessage.error(err instanceof Error ? err.message : String(err));
      return;
    }
    document.value = parsed;
    fileName.value = file.name;
    content.value = parsed.content;
    title.value = deriveOutlineTitleFromDocument(parsed, file.name);
    events.value = parseOutlineEvents(parsed.content);
    if (parsed.hasSettings) {
      ElMessage.success(`已识别小说设定：${parsed.settingsSummary}`);
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    reading.value = false;
  }
}

async function insertChapters(outlineId: number, list: ParsedOutlineEvent[], now: string) {
  for (const item of list) {
    await api.createRow('deepseek', 'outline_chapters', {
      outline_id: outlineId,
      event_index: item.eventIndex,
      event_type: item.eventType,
      event_title: item.eventTitle,
      event_summary: item.eventSummary,
      content: '',
      status: 'pending',
      created_at: now,
      updated_at: now,
    });
  }
}

async function confirmImport() {
  const parsed = document.value;
  if (!parsed || importing.value) return;
  const meta = parsed.meta;
  const finalTitle = title.value.trim() || meta.title.trim() || '未命名大纲';
  importing.value = true;
  const now = new Date().toISOString();

  // 1) 先新建作品记录（正文 + 小说设定 + 人物档案）；失败则整体中止
  let outlineId: number;
  try {
    const created = await api.createRow('deepseek', 'outline_records', {
      title: finalTitle,
      genre: meta.genre,
      theme: meta.theme,
      protagonist: meta.protagonist,
      worldview: meta.worldview,
      foreshadows: meta.foreshadows,
      characters: charactersToDbJson(meta.characters),
      content: content.value,
      created_at: now,
    });
    outlineId = Number(created.pk);
    if (!Number.isFinite(outlineId) || outlineId <= 0) {
      throw new Error('新建作品失败：服务端没有返回记录 id');
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
    importing.value = false;
    return;
  }

  // 2) 写入事件结构；失败不回滚已创建的作品记录（规格 2.2 第 7 条）
  try {
    await insertChapters(outlineId, events.value, now);
    const extra = parsed.hasSettings ? '，含小说设定' : '';
    ElMessage.success(`已导入《${finalTitle}》，共 ${events.value.length} 个事件${extra}`);
  } catch {
    ElMessage.warning('已导入，但事件结构解析失败（可进大纲编辑后重试）');
  } finally {
    importing.value = false;
  }

  visible.value = false;
  router.push(`/writing/outline/${outlineId}/edit`);
}
</script>

<template>
  <el-dialog v-model="visible" title="导入大纲 txt" width="640px" top="8vh" :close-on-click-modal="false">
    <div class="import-body">
      <p class="dialog-desc">
        选一个 .txt 文件，导入后<b>新建</b>一部作品大纲（不经过 AI，不会覆盖已有数据）。
        支持导出生成的 v2 结构化格式（正文 + 世界观 / 人物档案等设定），也兼容纯正文 txt。
      </p>

      <div class="pick-row">
        <el-button :icon="Upload" :loading="reading" @click="pickFile">选择 txt 文件</el-button>
        <span class="pick-hint">支持 UTF-8 / UTF-16 编码的 .txt</span>
        <input ref="fileInput" type="file" accept=".txt" class="file-input" @change="handleFileChange" />
      </div>

      <template v-if="hasFile">
        <el-form label-width="64px" class="import-form">
          <el-form-item label="标题">
            <el-input v-model="title" maxlength="120" placeholder="未命名大纲" />
          </el-form-item>
        </el-form>

        <div class="meta-row">
          <span class="meta-file" :title="fileName">文件名：{{ fileName }}</span>
          <span>{{ charCount }} 字</span>
          <span>识别到 {{ eventCount }} 个事件</span>
        </div>

        <div v-if="settingsSummary" class="settings-hint">
          已识别小说设定：{{ settingsSummary }}
        </div>

        <div v-if="eventCount === 0" class="warn-hint">
          没有识别到大纲事件，仍可导入后手动整理。
        </div>

        <pre v-if="content" class="preview">{{ previewLines.join('\n') }}<template v-if="hasMorePreview">…</template></pre>
        <div v-else class="empty-hint">该文件没有大纲正文，将只导入小说设定。</div>
      </template>

      <div v-else-if="!reading" class="empty-hint">
        还没有选择文件，点上面的按钮选一个 .txt。
      </div>
    </div>

    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="importing" :disabled="!hasFile || reading" @click="confirmImport">
        导入
      </el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.dialog-desc {
  margin: 0 0 14px;
  font-size: 13px;
  line-height: 1.7;
  color: var(--ink-2);
}

.dialog-desc b { color: var(--ink-1); }

.pick-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }

.pick-hint { font-size: 12px; color: var(--ink-4); }

.file-input { display: none; }

.import-form { margin-top: 14px; }

.meta-row {
  display: flex;
  align-items: center;
  gap: 14px;
  flex-wrap: wrap;
  font-size: 12.5px;
  color: var(--ink-3);
}

.meta-file {
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.settings-hint {
  margin-top: 10px;
  padding: 9px 12px;
  border-radius: 9px;
  border: 1px solid #c9d2ff;
  background: #f2f4ff;
  color: var(--ink-2);
  font-size: 12.5px;
  line-height: 1.6;
}

.warn-hint {
  margin-top: 10px;
  padding: 9px 12px;
  border-radius: 9px;
  border: 1px solid #fde68a;
  background: var(--warn-soft);
  color: #92400e;
  font-size: 12.5px;
  line-height: 1.6;
}

.preview {
  max-height: 180px;
  overflow: auto;
  margin: 12px 0 0;
  padding: 12px 14px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--bg-soft);
  font-family: 'Source Han Serif SC', 'Songti SC', 'STSong', serif;
  font-size: 12.5px;
  line-height: 1.75;
  color: var(--ink-2);
  white-space: pre-wrap;
  word-break: break-all;
}
</style>
