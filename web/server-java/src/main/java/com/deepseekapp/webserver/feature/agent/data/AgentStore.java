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

    @Delete("DELETE FROM agent_messages WHERE session_id = #{sessionId}")
    int deleteMessages(@Param("sessionId") long sessionId);

    @Delete("DELETE FROM agent_tasks WHERE session_id = #{sessionId}")
    int deleteTasks(@Param("sessionId") long sessionId);

    // ── 消息 ──

    @Insert("INSERT INTO agent_messages (session_id, device_id, role, content, parts, status, error, elapsed_ms, created_at) " +
            "VALUES (#{sessionId}, #{deviceId}, #{role}, #{content}, #{parts}, #{status}, #{error}, #{elapsedMs}, #{now})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    int insertMessage(Map<String, Object> row);

    @Select("SELECT * FROM agent_messages WHERE session_id = #{sessionId} ORDER BY id ASC")
    List<Map<String, Object>> listMessages(@Param("sessionId") long sessionId);

    // ── 设置 ──

    @Select("SELECT * FROM agent_settings WHERE device_id = #{deviceId}")
    Map<String, Object> findSettings(@Param("deviceId") String deviceId);

    @Insert("INSERT INTO agent_settings (device_id, api_key, base_url, model, temperature, max_tokens, top_p, " +
            "frequency_penalty, presence_penalty, system_prompt, web_search, search_count, search_need_content, updated_at) " +
            "VALUES (#{deviceId}, #{apiKey}, #{baseUrl}, #{model}, #{temperature}, #{maxTokens}, #{topP}, " +
            "#{frequencyPenalty}, #{presencePenalty}, #{systemPrompt}, #{webSearch}, #{searchCount}, " +
            "#{searchNeedContent}, #{now}) " +
            "ON DUPLICATE KEY UPDATE api_key = VALUES(api_key), base_url = VALUES(base_url), model = VALUES(model), " +
            "temperature = VALUES(temperature), max_tokens = VALUES(max_tokens), top_p = VALUES(top_p), " +
            "frequency_penalty = VALUES(frequency_penalty), presence_penalty = VALUES(presence_penalty), " +
            "system_prompt = VALUES(system_prompt), web_search = VALUES(web_search), " +
            "search_count = VALUES(search_count), search_need_content = VALUES(search_need_content), " +
            "updated_at = VALUES(updated_at)")
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
}
