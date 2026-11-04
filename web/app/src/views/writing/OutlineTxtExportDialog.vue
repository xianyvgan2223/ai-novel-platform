<script setup lang="ts">
/** 「导出大纲 txt」弹窗：选一部作品 → 取大纲正文 → 前端生成 UTF-8 + BOM 的 txt 下载 */
import { computed, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import type { Row } from '@/api';
import { loadOutline, loadOutlines } from './novelApi';
import { outlineFileName } from './outlineTxtTransfer';

const props = defineProps<{ modelValue: boolean }>();
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const outlines = ref<Row[]>([]);
const selectedId = ref<number | null>(null);
const loading = ref(false);
const exporting = ref(false);

const hasOutlines = computed(() => outlines.value.length > 0);

function titleOf(row: Row): string {
  return String(row.title ?? '').trim() || '未命名作品';
}

/**
 * 导出文件名 / 成功提示里的书名：空书名按规格用「未命名大纲」，
 * 与手机端导出文件名保持一致（列表里仍显示「未命名作品」保证可读）。
 */
function exportTitleOf(row: Row): string {
  return String(row.title ?? '').trim() || '未命名大纲';
}

/** created_at → 「2026-11-03」；解析不了时保留原文 */
function formatCreatedDate(value: unknown): string {
  const text = String(value ?? '').trim();
  if (!text) return '日期未知';
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return text;
  const pad = (num: number) => String(num).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

async function load() {
  loading.value = true;
  try {
    outlines.value = await loadOutlines();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    loading.value = false;
  }
}

/** 触发浏览器下载：a[download] + Blob（UTF-8 带 BOM，方便记事本认出中文） */
function downloadTxt(fileName: string, content: string) {
  const blob = new Blob(
    [new Uint8Array([0xef, 0xbb, 0xbf]), new TextEncoder().encode(content)],
    { type: 'text/plain;charset=utf-8' },
  );
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = fileName;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

async function exportOutline() {
  const id = selectedId.value;
  if (id === null || exporting.value) return;
  exporting.value = true;
  try {
    const row = await loadOutline(id);
    const content = String(row.content ?? '');
    if (!content.trim()) {
      ElMessage.warning('这部作品还没有大纲正文');
      return;
    }
    const title = exportTitleOf(row);
    downloadTxt(outlineFileName(title), content);
    ElMessage.success(`已导出《${title}》大纲`);
    visible.value = false;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    exporting.value = false;
  }
}

// 每次打开弹窗都重新拉取作品列表，避免看到删除前的旧数据
watch(
  () => props.modelValue,
  (opened) => {
    if (!opened) return;
    selectedId.value = null;
    void load();
  },
);
</script>

<template>
  <el-dialog v-model="visible" title="导出大纲 txt" width="540px" top="10vh">
    <div v-loading="loading" class="export-body">
      <p class="dialog-desc">
        选一部作品，把大纲正文原样导出为 <b>.txt</b> 文件（UTF-8 带 BOM，Windows 记事本可直接打开）。
      </p>

      <template v-if="hasOutlines">
        <el-select
          v-model="selectedId"
          class="full"
          filterable
          placeholder="选择要导出的作品"
        >
          <el-option
            v-for="item in outlines"
            :key="String(item.id)"
            :label="`${titleOf(item)} · ${formatCreatedDate(item.created_at)}`"
            :value="Number(item.id)"
          />
        </el-select>
        <p class="file-name-hint">
          文件名：{{ selectedId === null ? '《书名》大纲.txt' : outlineFileName(exportTitleOf(outlines.find((item) => Number(item.id) === selectedId) ?? {})) }}
        </p>
      </template>

      <div v-else-if="!loading" class="empty-hint">
        还没有可导出的作品，先去「一键生成大纲」创建。
      </div>
    </div>

    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button
        type="primary"
        :loading="exporting"
        :disabled="loading || selectedId === null"
        @click="exportOutline"
      >
        导出
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

.full { width: 100%; }

.file-name-hint {
  margin: 10px 0 0;
  font-size: 12px;
  color: var(--ink-3);
  word-break: break-all;
}
</style>
