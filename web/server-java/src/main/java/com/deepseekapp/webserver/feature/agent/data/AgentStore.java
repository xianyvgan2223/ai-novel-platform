package com.deepseekapp.webserver.feature.agent.data;

import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Options;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

import java.util.List;
import java.util.Map;

/**
 * Agent 面板持久层：会话、消息、设置、任务计划。
 *
 * <p>这里用 MyBatis 注解映射，参数与结果都是 Map，避免为四张纯展示表写大量实体；
 * 需要强类型的表继续用 MyBatis-Plus {@code BaseMapper}（见 DeviceMapper）。</p>
 */
@Mapper
public interface AgentStore {

    // ── 会话 ──

    @Insert("INSERT INTO agent_sessions (device_id, title, message_count, created_at, updated_at) " +
            "VALUES (#{deviceId}, #{title}, 0, #{now}, #{now})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    int insertSession(Map<String, Object> row);

    @Select("SELECT * FROM agent_sessions WHERE device_id = #{deviceId} ORDER BY updated_at DESC LIMIT #{limit}")
    List<Map<String, Object>> listSessions(@Param("deviceId") String deviceId, @Param("limit") int limit);

    @Select("SELECT * FROM agent_sessions WHERE id = #{id} AND device_id = #{deviceId}")
    Map<String, Object> findSession(@Param("id") long id, @Param("deviceId") String deviceId);

    @Update("UPDATE agent_sessions SET message_count = message_count + 1, updated_at = #{now} " +
            "WHERE id = #{id} AND device_id = #{deviceId}")
    int touchSession(@Param("id") long id, @Param("deviceId") String deviceId, @Param("now") long now);

    @Update("UPDATE agent_sessions SET title = #{title}, updated_at = #{now} WHERE id = #{id} AND device_id = #{deviceId}")
    int renameSession(@Param("id") long id, @Param("deviceId") String deviceId,
                      @Param("title") String title, @Param("now") long now);

    @Delete("DELETE FROM agent_sessions WHERE id = #{id} AND device_id = #{deviceId}")
    int deleteSession(@Param("id") long id, @Param("deviceId") String deviceId);

    @Delete("DELETE FROM agent_messages WHERE session_id = #{sessionId} AND device_id = #{deviceId}")
    int deleteMessages(@Param("sessionId") long sessionId, @Param("deviceId") String deviceId);

    @Delete("DELETE FROM agent_tasks WHERE session_id = #{sessionId} AND device_id = #{deviceId}")
    int deleteTasks(@Param("sessionId") long sessionId, @Param("deviceId") String deviceId);

    @Delete("DELETE FROM agent_runs WHERE session_id = #{sessionId} AND device_id = #{deviceId}")
    int deleteRuns(@Param("sessionId") long sessionId, @Param("deviceId") String deviceId);

    // ── 消息 ──

    @Insert("INSERT INTO agent_messages (session_id, device_id, role, content, parts, status, error, elapsed_ms, " +
            "run_id, prompt_tokens, completion_tokens, cached_tokens, created_at) " +
            "VALUES (#{sessionId}, #{deviceId}, #{role}, #{content}, #{parts}, #{status}, #{error}, #{elapsedMs}, " +
            "#{runId}, #{promptTokens}, #{completionTokens}, #{cachedTokens}, #{now})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    int insertMessage(Map<String, Object> row);

    @Select("SELECT * FROM agent_messages WHERE session_id = #{sessionId} ORDER BY id ASC")
    List<Map<String, Object>> listMessages(@Param("sessionId") long sessionId);

    /** 摘要之后的消息（倒序取最近 limit 条，由调用方翻转）。 */
    @Select("SELECT * FROM agent_messages WHERE session_id = #{sessionId} AND id > #{afterId} " +
            "ORDER BY id DESC LIMIT #{limit}")
    List<Map<String, Object>> listMessagesAfter(@Param("sessionId") long sessionId,
                                                @Param("afterId") long afterId,
                                                @Param("limit") int limit);

    @Update("UPDATE agent_sessions SET summary = #{summary}, summary_upto = #{upto}, updated_at = #{now} " +
            "WHERE id = #{id} AND device_id = #{deviceId}")
    int updateSummary(@Param("id") long id, @Param("deviceId") String deviceId,
                      @Param("summary") String summary, @Param("upto") long upto,
                      @Param("now") long now);

    @Update("UPDATE agent_sessions SET context_tokens = #{tokens}, context_cached_tokens = #{cached}, " +
            "total_prompt_tokens = total_prompt_tokens + #{tokens}, " +
            "total_cached_tokens = total_cached_tokens + #{cached} " +
            "WHERE id = #{id} AND device_id = #{deviceId}")
    int updateContextTokens(@Param("id") long id, @Param("deviceId") String deviceId,
                            @Param("tokens") long tokens, @Param("cached") long cached);

    /** 会话累计用量（Σ prompt / Σ cache hit），用于展示整体缓存命中率。 */
    @Select("SELECT total_prompt_tokens AS prompt, total_cached_tokens AS cached FROM agent_sessions " +
            "WHERE id = #{id} AND device_id = #{deviceId}")
    Map<String, Object> usageTotals(@Param("id") long id, @Param("deviceId") String deviceId);

    // ── 设置 ──

    @Select("SELECT * FROM agent_settings WHERE device_id = #{deviceId}")
    Map<String, Object> findSettings(@Param("deviceId") String deviceId);

    @Insert("INSERT INTO agent_settings (device_id, api_key, base_url, model, temperature, max_tokens, top_p, " +
            "frequency_penalty, presence_penalty, system_prompt, context_window, web_search, search_count, search_need_content, " +
            "stream, thinking, reasoning_effort, updated_at) " +
            "VALUES (#{deviceId}, #{apiKey}, #{baseUrl}, #{model}, #{temperature}, #{maxTokens}, #{topP}, " +
            "#{frequencyPenalty}, #{presencePenalty}, #{systemPrompt}, #{contextWindow}, #{webSearch}, #{searchCount}, " +
            "#{searchNeedContent}, #{stream}, #{thinking}, #{reasoningEffort}, #{now}) " +
            "ON DUPLICATE KEY UPDATE api_key = VALUES(api_key), base_url = VALUES(base_url), model = VALUES(model), " +
            "temperature = VALUES(temperature), max_tokens = VALUES(max_tokens), top_p = VALUES(top_p), " +
            "frequency_penalty = VALUES(frequency_penalty), presence_penalty = VALUES(presence_penalty), " +
            "system_prompt = VALUES(system_prompt), context_window = VALUES(context_window), web_search = VALUES(web_search), " +
            "search_count = VALUES(search_count), search_need_content = VALUES(search_need_content), " +
            "stream = VALUES(stream), thinking = VALUES(thinking), " +
            "reasoning_effort = VALUES(reasoning_effort), updated_at = VALUES(updated_at)")
    int upsertSettings(Map<String, Object> row);

    // ── 任务计划 ──

    @Insert("INSERT INTO agent_tasks (session_id, device_id, run_id, title, steps, status, created_at, updated_at) " +
            "VALUES (#{sessionId}, #{deviceId}, #{runId}, #{title}, #{steps}, 'running', #{now}, #{now})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    int insertTask(Map<String, Object> row);

    @Update("UPDATE agent_tasks SET steps = #{steps}, status = #{status}, updated_at = #{now} WHERE id = #{id}")
    int updateTask(@Param("id") long id, @Param("steps") String steps,
                   @Param("status") String status, @Param("now") long now);

    @Select("SELECT * FROM agent_tasks WHERE id = #{id}")
    Map<String, Object> findTask(@Param("id") long id);

    @Select("SELECT * FROM agent_tasks WHERE session_id = #{sessionId} ORDER BY id ASC")
    List<Map<String, Object>> listTasks(@Param("sessionId") long sessionId);

    /** 进程重启时把没来得及结束的计划标成 interrupted，避免面板永远转圈。 */
    @Update("UPDATE agent_tasks SET status = 'interrupted', updated_at = #{now} WHERE status = 'running'")
    int markTasksInterrupted(@Param("now") long now);

    // ── 运行日志（断联/重启恢复）──

    @Insert("INSERT INTO agent_runs (run_id, device_id, session_id, status, last_seq, started_at) " +
            "VALUES (#{runId}, #{deviceId}, #{sessionId}, 'running', 0, #{now})")
    int insertRun(Map<String, Object> row);

    @Update("UPDATE agent_runs SET last_seq = #{lastSeq}, text_so_far = #{text}, parts_json = #{parts}, " +
            "status = #{status} WHERE run_id = #{runId}")
    int checkpointRun(@Param("runId") String runId, @Param("lastSeq") long lastSeq,
                      @Param("text") String text, @Param("parts") String parts,
                      @Param("status") String status);

    @Update("UPDATE agent_runs SET last_seq = #{lastSeq}, text_so_far = #{text}, parts_json = #{parts}, " +
            "status = #{status}, error = #{error}, finished_at = #{now} WHERE run_id = #{runId}")
    int finishRun(@Param("runId") String runId, @Param("lastSeq") long lastSeq,
                  @Param("text") String text, @Param("parts") String parts,
                  @Param("status") String status, @Param("error") String error,
                  @Param("now") long now);

    /** 进程启动时上一轮没来得及结束的运行。 */
    @Select("SELECT * FROM agent_runs WHERE status = 'running'")
    List<Map<String, Object>> runningRuns();

    @Update("UPDATE agent_runs SET status = 'interrupted', finished_at = #{now} WHERE status = 'running'")
    int markInterrupted(@Param("now") long now);

    @Select("SELECT COUNT(*) AS c FROM agent_messages WHERE run_id = #{runId}")
    long countMessagesByRun(@Param("runId") String runId);

    // ── 下载库 ──

    @Insert("INSERT INTO agent_downloads (device_id, url, filename, mime, size, path, status, error, created_at) " +
            "VALUES (#{deviceId}, #{url}, #{filename}, #{mime}, #{size}, #{path}, #{status}, #{error}, #{createdAt})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    int insertDownload(Map<String, Object> row);

    @Select("SELECT * FROM agent_downloads WHERE device_id = #{deviceId} ORDER BY id DESC LIMIT #{limit}")
    List<Map<String, Object>> listDownloads(@Param("deviceId") String deviceId, @Param("limit") int limit);

    @Select("SELECT * FROM agent_downloads WHERE id = #{id} AND device_id = #{deviceId}")
    Map<String, Object> findDownload(@Param("id") long id, @Param("deviceId") String deviceId);

    @Delete("DELETE FROM agent_downloads WHERE id = #{id} AND device_id = #{deviceId}")
    int deleteDownload(@Param("id") long id, @Param("deviceId") String deviceId);
}
