<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import { Refresh } from '@element-plus/icons-vue';
import { api } from '@/api';
import type { Row } from '@/api';
import { eventNumbers, isMajor, loadOutlines } from './novelApi';
import type { InspirationSession, OutlineEvent } from './inspirationApi';

const props = defineProps<{ modelValue: boolean; session: InspirationSession | null }>();
const emit = defineEmits<{
  (event: 'update:modelValue', value: boolean): void;
  (event: 'saved', payload: { outlineRecordId: number | null; outlineTitle: string; events: OutlineEvent[] }): void;
}>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const outlines = ref<Row[]>([]);
const selectedId = ref<number | null>(null);
const chapters = ref<Row[]>([]);
const loading = ref(false);
const chaptersLoading = ref(false);
const picked = ref<Set<number>>(new Set());

const numbers = computed(() => eventNumbers(chapters.value));
const selectedOutline = computed(() => outlines.value.find((row) => Number(row.id) === selectedId.value) ?? null);

watch(
  () => props.modelValue,
  (open) => {
    if (open) void loadOutlinesAndPick();
  },
);

async function loadOutlinesAndPick(): Promise<void> {
  loading.value = true;
  try {
    outlines.value = await loadOutlines();
    const wanted = props.session?.outlineRecordId ?? null;
    const exists = wanted != null && outlines.value.some((row) => Number(row.id) === wanted);
    if (exists) {
      selectedId.value = wanted;
    } else if (outlines.value.length) {
      selectedId.value = Number(outlines.value[0].id);
    } else {
      selectedId.value = null;
    }
    chapters.value = [];
    picked.value = new Set();
    if (selectedId.value != null) await loadChaptersFor(selectedId.value, true);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

async function loadChaptersFor(outlineId: number, preselect: boolean): Promise<void> {
  chaptersLoading.value = true;
  try {
    const res = await api.listRows('deepseek', 'outline_chapters', {
      outline_id: outlineId,
      page: 1,
      pageSize: 1000,
      orderBy: 'event_index',
      dir: 'asc',
      // 灵感需要完整概要；列表默认只给 300 字
      maxTextLength: 6000,
    });
    chapters.value = res.data;
    if (preselect && props.session?.outlineRecordId === outlineId) {
      const wanted = new Set(props.session.events.map((item) => item.chapterId).filter((id): id is number => id != null));
      picked.value = new Set(chapters.value.filter((row) => wanted.has(Number(row.id))).map((row) => Number(row.id)));
    } else {
      picked.value = new Set();
    }
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    chaptersLoading.value = false;
  }
}

async function changeOutline(id: number | null): Promise<void> {
  if (id == null) return;
  await loadChaptersFor(id, false);
}

function toggle(row: Row, value: boolean): void {
  const next = new Set(picked.value);
  const id = Number(row.id);
  if (value) next.add(id);
  else next.delete(id);
  picked.value = next;
}

function toggleAll(value: boolean): void {
  picked.value = value ? new Set(chapters.value.map((row) => Number(row.id))) : new Set();
}

function save(): void {
  const outline = selectedOutline.value;
  if (!outline || selectedId.value == null) {
    ElMessage.warning('先选一部作品');
    return;
  }
  const events: OutlineEvent[] = chapters.value
    .filter((row) => picked.value.has(Number(row.id)))
    .map((row) => {
      const number = numbers.value.get(Number(row.id));
      return {
        chapterId: Number(row.id),
        type: isMajor(row) ? 'major' : 'minor',
        title: String(row.event_title ?? '').trim() || '未命名事件',
        summary: String(row.event_summary ?? '').trim(),
        majorNumber: number?.kind === 'major' ? number.number : null,
        minorNumber: number?.kind === 'minor' ? number.number : null,
      };
    });
  emit('saved', {
    outlineRecordId: selectedId.value,
    outlineTitle: String(outline.title ?? '').trim() || '未命名作品',
    events,
  });
  visible.value = false;
}

function clearSelection(): void {
  emit('saved', { outlineRecordId: null, outlineTitle: '', events: [] });
  visible.value = false;
}
</script>

<template>
  <el-dialog v-model="visible" title="从已有大纲导入事件" width="min(760px, 94vw)" append-to-body>
    <div v-loading="loading" class="outline-picker">
      <div class="picker-row">
        <el-select
          :model-value="selectedId"
          filterable
          placeholder="选择作品"
          class="outline-select"
          @change="(value) => changeOutline(value as number | null)"
        >
          <el-option
            v-for="item in outlines"
            :key="String(item.id)"
            :label="String(item.title || '未命名作品')"
            :value="Number(item.id)"
          />
        </el-select>
        <el-button :icon="Refresh" :loading="loading" @click="loadOutlinesAndPick">刷新</el-button>
        <el-button text @click="clearSelection">清除已导入</el-button>
      </div>

      <div v-if="!outlines.length && !loading" class="empty-hint">还没有作品大纲。</div>

      <template v-else-if="selectedId != null">
        <div class="picker-tools">
          <el-checkbox
            :model-value="picked.size === chapters.length && chapters.length > 0"
            :indeterminate="picked.size > 0 && picked.size < chapters.length"
            @change="(value) => toggleAll(Boolean(value))"
          >
            全选
          </el-checkbox>
          <span class="text-muted">已选 {{ picked.size }} 个事件</span>
          <span class="text-muted">导入后只作为本会话的推演范围，不会改动大纲。</span>
        </div>

        <div v-loading="chaptersLoading" class="chapter-list">
          <div v-if="!chapters.length && !chaptersLoading" class="empty-hint">这部作品还没有事件结构。</div>
          <template v-for="row in chapters" :key="String(row.id)">
            <div v-if="isMajor(row)" class="chapter-major">
              <el-checkbox
                :model-value="picked.has(Number(row.id))"
                @change="(value) => toggle(row, Boolean(value))"
              >
                大事件{{ numbers.get(Number(row.id))?.number ?? '' }}：{{ row.event_title || '未命名大事件' }}
              </el-checkbox>
            </div>
            <div v-else class="chapter-row">
              <el-checkbox
                :model-value="picked.has(Number(row.id))"
                @change="(value) => toggle(row, Boolean(value))"
              />
              <span class="chapter-main">
                <span class="chapter-title">
                  小事件{{ numbers.get(Number(row.id))?.number ?? '' }}：{{ row.event_title || '未命名小事件' }}
                </span>
                <span v-if="String(row.event_summary ?? '').trim()" class="chapter-summary">
                  {{ row.event_summary }}
                </span>
              </span>
            </div>
          </template>
        </div>
      </template>
    </div>

    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :disabled="!picked.size" @click="save">导入所选事件</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.outline-picker { min-height: 160px; }
.picker-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.outline-select { width: 280px; }
.picker-tools { display: flex; align-items: center; gap: 12px; margin-top: 12px; padding-bottom: 9px; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
.picker-tools :deep(.el-checkbox) { margin-right: 0; }
.picker-tools .text-muted { font-size: 11.5px; }

.chapter-list { max-height: 46vh; overflow-y: auto; margin-top: 6px; }
.chapter-major { padding: 10px 2px 4px; }
.chapter-major :deep(.el-checkbox__label) { font-size: 12px; font-weight: 600; color: var(--ink-3); }
.chapter-row { display: flex; align-items: flex-start; gap: 4px; padding: 7px 6px; border-radius: 7px; cursor: pointer; }
.chapter-row:hover { background: var(--bg-soft); }
.chapter-main { display: flex; flex-direction: column; gap: 3px; min-width: 0; flex: 1; }
.chapter-title { font-size: 12px; color: var(--ink-2); }
.chapter-summary { font-size: 11px; line-height: 1.65; color: var(--ink-4); }
</style>