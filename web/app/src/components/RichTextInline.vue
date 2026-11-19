<script setup lang="ts">
import type { Inline } from './markdown';

defineProps<{ items: Inline[] }>();
</script>

<template>
  <span
    ><template v-for="(s, i) in items" :key="i"
      ><strong v-if="s.t === 'bold'">{{ s.v }}</strong
      ><em v-else-if="s.t === 'italic'">{{ s.v }}</em
      ><del v-else-if="s.t === 'strike'">{{ s.v }}</del
      ><code v-else-if="s.t === 'code'" class="rt-inline">{{ s.v }}</code
      ><a
        v-else-if="s.t === 'link' && s.href"
        class="rt-link"
        :href="s.href"
        target="_blank"
        rel="noopener noreferrer"
        >{{ s.v }}</a
      ><template v-else>{{ s.v }}</template></template
    ></span
  >
</template>

<style scoped>
strong {
  font-weight: 650;
  color: var(--ink-1);
}

em {
  font-style: italic;
}

del {
  color: var(--ink-3);
}

.rt-inline {
  padding: 1px 5px;
  border-radius: 4px;
  background: var(--code-inline-bg);
  font-family: 'JetBrains Mono', 'Cascadia Mono', Consolas, monospace;
  font-size: 0.92em;
  color: var(--code-inline-text);
}

.rt-link {
  color: var(--brand);
  text-decoration: underline;
  text-underline-offset: 2px;
  word-break: break-all;
}
</style>
