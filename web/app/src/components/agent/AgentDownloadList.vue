<!--
  AgentDownloadList.vue —— 下载库列表
  支持保存到本机（带设备头拉 blob）与删除服务端文件。
-->
<script setup lang="ts">
import { ElMessage, ElMessageBox } from 'element-plus';
import { Delete, Download, Refresh } from '@element-plus/icons-vue';
import { fetchBlob } from '@/api/client';
import { formatTime } from '@/api';
import type { AgentDownload } from '@/api/agent';

defineProps<{ items: AgentDownload[]; loading?: boolean; showHead?: boolean }>();
const emit = defineEmits<{ (event: 'refresh'): void; (event: 'delete', id: number): void }>();

function formatSize(bytes: number): string {
  if (!bytes || bytes <= 0) return '0 B';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1024 / 1024).toFixed(2) + ' MB';
}

async function saveToLocal(item: AgentDownload): Promise<void> {
  try {
    const blob = await fetchBlob(item.downloadUrl);
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = item.filename || 'download';
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  } catch (error) {
    ElMessage.error(error instanceof Error ? error.message : String(error));
  }
}

async function remove(item: AgentDownload): Promise<void> {
  try {
    await ElMessageBox.confirm(`删除「${item.filename}」？服务端文件也会被删除。`, '删除下载', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  emit('delete', item.id);
}
</script>

<template>
  <div class="download-list">
    <div v-if="showHead !== false" class="download-head">
      <span class="download-count">{{ items.length }} 个文件</span>
      <el-button text size="small" :icon="Refresh" @click="emit('refresh')">刷新</el-button>
    </div>

    <div v-if="!items.length" class="download-empty">
      Agent 通过 download_file 下载的文件会出现在这里
    </div>

    <div v-for="item in items" :key="item.id" class="download-item">
      <div class="download-main">
        <div class="download-name">{{ item.filename || '未命名文件' }}</div>
        <div class="download-meta">
          <span>{{ formatSize(item.size) }}</span>
          <span>·</span>
          <span>{{ formatTime(item.createdAt) }}</span>
          <span v-if="item.status === 'failed'" class="download-failed">失败</span>
        </div>
        <div v-if="item.error" class="download-error">{{ item.error }}</div>
      </div>
      <div class="download-actions">
        <el-tooltip content="保存到本机" placement="top">
          <el-button text circle :icon="Download" :disabled="item.status !== 'done'" @click="saveToLocal(item)" />
        </el-tooltip>
        <el-tooltip content="删除" placement="top">
          <el-button text circle :icon="Delete" @click="remove(item)" />
        </el-tooltip>
      </div>
    </div>
  </div>
</template>

<style scoped>
.download-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
  max-height: 52vh;
  overflow-y: auto;
}

.download-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-bottom: 4px;
}

.download-count {
  font-size: 11.5px;
  color: var(--ink-3);
}

.download-empty {
  padding: 28px 12px;
  text-align: center;
  font-size: 11.5px;
  color: var(--ink-4);
}

.download-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border-radius: 7px;
  background: var(--bg-soft);
  box-shadow: var(--shadow-control);
}

.download-main {
  flex: 1;
  min-width: 0;
}

.download-name {
  font-size: 12px;
  color: var(--ink-1);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.download-meta {
  display: flex;
  gap: 5px;
  margin-top: 2px;
  font-size: 10.5px;
  color: var(--ink-4);
}

.download-failed {
  color: var(--danger);
}

.download-error {
  margin-top: 2px;
  font-size: 10.5px;
  color: var(--danger);
}

.download-actions {
  display: flex;
  gap: 2px;
  flex: 0 0 auto;
}
</style>
