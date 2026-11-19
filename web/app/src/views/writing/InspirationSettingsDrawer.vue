<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { ElMessage } from 'element-plus';
import type { InspirationSettings } from './inspirationApi';
import { saveSettings } from './inspirationApi';

const props = defineProps<{ modelValue: boolean; settings: InspirationSettings }>();
const emit = defineEmits<{ (event: 'update:modelValue', value: boolean): void; (event: 'saved', value: InspirationSettings): void }>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit('update:modelValue', value),
});

const form = ref<InspirationSettings>({ ...props.settings });
const saving = ref(false);

watch(
  () => props.modelValue,
  (open) => {
    if (open) form.value = { ...props.settings };
  },
);

async function save(): Promise<void> {
  saving.value = true;
  try {
    const next: InspirationSettings = {
      ...form.value,
      systemPrompt: form.value.systemPrompt.trim(),
      temperature: Math.min(2, Math.max(0, Number(form.value.temperature) || 0)),
      maxTokens: Math.min(32768, Math.max(256, Number(form.value.maxTokens) || 4096)),
      concurrency: Math.min(10, Math.max(1, Number(form.value.concurrency) || 3)),
    };
    await saveSettings(next);
    emit('saved', next);
    ElMessage.success('灵感设置已保存');
    visible.value = false;
  } catch (err) {
    ElMessage.error(err instanceof Error ? err.message : String(err));
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <el-drawer v-model="visible" title="小说灵感设置" size="420px" append-to-body>
    <el-form label-position="top" class="settings-form">
      <el-form-item label="模型">
        <el-select v-model="form.model" filterable allow-create class="full">
          <el-option label="DeepSeek Flash（快）" value="deepseek-flash" />
          <el-option label="DeepSeek Pro（推理强）" value="deepseek-v4-pro" />
        </el-select>
      </el-form-item>

      <el-form-item label="Temperature">
        <el-input-number v-model="form.temperature" :min="0" :max="2" :step="0.1" controls-position="right" class="full" />
        <div class="hint">越高越发散；推演新剧情建议 0.8~1.1。</div>
      </el-form-item>

      <el-form-item label="Max Tokens">
        <el-input-number v-model="form.maxTokens" :min="256" :max="32768" :step="512" controls-position="right" class="full" />
        <div class="hint">单次推演的最大输出长度；长正文建议 4096 以上。</div>
      </el-form-item>

      <el-form-item label="并行推演数">
        <el-input-number v-model="form.concurrency" :min="1" :max="10" :step="1" controls-position="right" class="full" />
        <div class="hint">每次同时生成几个候选推演；越多越快，也越容易触发限流。</div>
      </el-form-item>

      <el-form-item label="系统提示词">
        <el-input
          v-model="form.systemPrompt"
          type="textarea"
          :rows="5"
          resize="vertical"
          placeholder="留空使用默认：你是一位中文小说作家，正在和作者一起推演小说剧情……"
        />
        <div class="hint">世界观、主题、人物卡和大纲事件会自动追加在后面。</div>
      </el-form-item>
    </el-form>

    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="saving" @click="save">保存</el-button>
    </template>
  </el-drawer>
</template>

<style scoped>
.settings-form { padding-right: 4px; }
.full { width: 100%; }
.hint { margin-top: 5px; font-size: 11px; line-height: 1.6; color: var(--ink-4); }
</style>