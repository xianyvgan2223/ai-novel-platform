<script setup lang="ts">
/**
 * 下载页：把 Agent 的 download_file 工具与下载库文件放到前台，
 * 不用打开 Agent 面板也能查看、保存到本机或删除服务端文件。
 */
import { computed, onMounted } from 'vue';
import { ElMessage } from 'element-plus';
import { Refresh, Tools } from '@element-plus/icons-vue';
import PageHeader from '@/components/PageHeader.vue';
import AgentDownloadList from '@/components/agent/AgentDownloadList.vue';
import { useAgentStore } from '@/stores/agent';

const agent = useAgentStore();

/** 只展示与下载有关的工具（download_file） */
const downloadTools = computed(() =>
  agent.tools.filter((tool) => /download/i.test(tool.name) || /下载/.test(tool.description)),
);

const totalSize = computed(() => agent.downloads.reduce((sum, item) => sum + (Number(item.size) || 0), 0));

function formatSize(bytes: number): string {
  if (!bytes || bytes <= 0) return '0 B';
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1024 / 1024).toFixed(2) + ' MB';
}

async function load(): Promise<void> {
  try {
    await Promise.all([agent.loadTools(), agent.loadDownloads()]);
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function refreshDownloads(): Promise<void> {
  try {
    await agent.loadDownloads();
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

async function removeDownload(id: number): Promise<void> {
  try {
    await agent.deleteDownload(id);
    ElMessage.success('已删除服务端文件');
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  }
}

onMounted(() => {
  void load();
});
</script>

<template>
  <div class="page">
    <PageHeader
      title="下载"
      desc="Agent 通过 download_file 工具下载的文件保存在服务端；这里可以查看下载工具与文件，保存到本机或删除。"
    >
      <template #actions>
        <el-button :icon="Refresh" @click="load">刷新</el-button>
      </template>
    </PageHeader>

    <section class="card card-flush download-tools">
      <div class="card-head">
        <h3><el-icon class="head-icon"><Tools /></el-icon> 下载工具</h3>
        <span class="mono text-muted">Agent 工具</span>
      </div>
      <div class="card-body">
        <div v-if="!downloadTools.length" class="empty-hint">
          还没有读到 Agent 工具列表；启动 Agent 面板或点右上角刷新后，download_file 会显示在这里。
        </div>
        <div v-for="tool in downloadTools" :key="tool.name" class="tool-row">
          <span class="tool-name">{{ tool.name }}</span>
          <p class="tool-desc">{{ tool.description }}</p>
        </div>
      </div>
    </section>

    <section class="card card-flush download-files">
      <div class="card-head">
        <h3>下载内容</h3>
        <div class="download-head-actions">
          <span class="mono text-muted">{{ agent.downloads.length }} 个文件 · {{ formatSize(totalSize) }}</span>
          <el-button text size="small" :icon="Refresh" @click="refreshDownloads">刷新</el-button>
        </div>
      </div>
      <div class="card-body">
        <AgentDownloadList
          :items="agent.downloads"
          :show-head="false"
          @refresh="refreshDownloads"
          @delete="removeDownload"
        />
      </div>
    </section>
  </div>
</template>

<style scoped>
.head-icon { font-size: 15px; vertical-align: -2px; margin-right: 2px; }

.download-tools { margin-bottom: 18px; }
.download-files { margin-bottom: 18px; }
.download-head-actions { display: flex; align-items: center; gap: 10px; }

.tool-row {
  padding: 11px 0;
  border-bottom: 1px solid var(--line);
}

.tool-row:last-child { border-bottom: none; }

.tool-name {
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 12px;
  font-weight: 600;
  color: var(--ink-1);
}

.tool-desc {
  margin: 5px 0 0;
  font-size: 12.5px;
  line-height: 1.7;
  color: var(--ink-2);
}
</style>