package com.deepseekapp.webserver.db;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 极薄的 JDBC 辅助层：动态 SQL、值归一化、事务。 */
public final class Db {

    @FunctionalInterface
    public interface SqlAction {
        void run() throws Exception;
    }

    private Db() {
    }

    /**
     * 把 JDBC 读出的值归一化成与 Node 版 node:sqlite 尽量一致的形态：
     * 整数统一为 Long；REAL 中恰好是整数的值也收敛成 Long（JSON 里不会出现 1.0）。
     */
    public static Object normalize(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Boolean b) {
            return b ? 1L : 0L;
        }
        if (value instanceof Byte || value instanceof Short || value instanceof Integer) {
            return ((Number) value).longValue();
        }
        if (value instanceof Long) {
            return value;
        }
        if (value instanceof BigInteger bi) {
            return bi.longValue();
        }
        if (value instanceof Float || value instanceof Double) {
            double d = ((Number) value).doubleValue();
            if (Double.isFinite(d) && d == Math.rint(d) && Math.abs(d) <= 9.007199254740992E15) {
                return (long) d;
            }
            return d;
        }
        if (value instanceof BigDecimal bd) {
            return bd.doubleValue();
        }
        if (value instanceof byte[] bytes) {
            return Base64.getEncoder().encodeToString(bytes);
        }
        return value;
    }

    public static void exec(Connection connection, String sql) {
        try (Statement st = connection.createStatement()) {
            // sqlite-jdbc 的 Statement.execute 只执行第一条语句，初始化 DDL 里有多条，
            // 这里显式按分号拆分逐条执行。
            for (String statement : sql.split(";")) {
                String one = statement.trim();
                if (!one.isEmpty()) {
                    st.execute(one);
                }
            }
        } catch (SQLException e) {
            throw new RuntimeException("执行 SQL 失败：" + e.getMessage(), e);
        }
    }

    public static int update(Connection connection, String sql, Object... args) {
        try (PreparedStatement ps = connection.prepareStatement(sql)) {
            bind(ps, args);
            return ps.executeUpdate();
        } catch (SQLException e) {
            throw new RuntimeException("执行 SQL 失败：" + e.getMessage(), e);
        }
    }

    public static long insertReturningId(Connection connection, String sql, Object... args) {
        try (PreparedStatement ps = connection.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {
            bind(ps, args);
            ps.executeUpdate();
            try (ResultSet keys = ps.getGeneratedKeys()) {
                if (keys.next()) {
                    return keys.getLong(1);
                }
            }
        } catch (SQLException e) {
            throw new RuntimeException("执行 SQL 失败：" + e.getMessage(), e);
        }
        Map<String, Object> row = queryOne(connection, "SELECT last_insert_rowid() AS id");
        return row == null ? 0L : ((Number) row.get("id")).longValue();
    }

    public static List<Map<String, Object>> query(Connection connection, String sql, Object... args) {
        try (PreparedStatement ps = connection.prepareStatement(sql)) {
            bind(ps, args);
            try (ResultSet rs = ps.executeQuery()) {
                ResultSetMetaData meta = rs.getMetaData();
                int count = meta.getColumnCount();
                List<Map<String, Object>> rows = new ArrayList<>();
                while (rs.next()) {
                    Map<String, Object> row = new LinkedHashMap<>();
                    for (int i = 1; i <= count; i++) {
                        row.put(meta.getColumnLabel(i), normalize(rs.getObject(i)));
                    }
                    rows.add(row);
                }
                return rows;
            }
        } catch (SQLException e) {
            throw new RuntimeException("查询失败：" + e.getMessage(), e);
        }
    }

    public static Map<String, Object> queryOne(Connection connection, String sql, Object... args) {
        List<Map<String, Object>> rows = query(connection, sql, args);
        return rows.isEmpty() ? null : rows.get(0);
    }

    /**
     * 事务包装。若连接已经在事务中（autoCommit=false），直接执行，
     * 由外层负责提交/回滚，避免 SQLite 报 "cannot start a transaction within a transaction"。
     */
    public static void transaction(Connection connection, SqlAction action) {
        boolean wasAutoCommit;
        try {
            wasAutoCommit = connection.getAutoCommit();
        } catch (SQLException e) {
            throw new RuntimeException("读取事务状态失败", e);
        }
        if (!wasAutoCommit) {
            runAction(action);
            return;
        }
        try {
            connection.setAutoCommit(false);
            runAction(action);
            connection.commit();
        } catch (Exception e) {
            try {
                connection.rollback();
            } catch (SQLException ignore) {
                // 保留原始异常
            }
            if (e instanceof RuntimeException re) {
                throw re;
            }
            throw new RuntimeException("事务执行失败：" + e.getMessage(), e);
        } finally {
            try {
                connection.setAutoCommit(true);
            } catch (SQLException ignore) {
                // 忽略恢复失败
            }
        }
    }

    private static void runAction(SqlAction action) {
        try {
            action.run();
        } catch (RuntimeException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException(e.getMessage(), e);
        }
    }

    public static void bind(PreparedStatement ps, Object... args) throws SQLException {
        for (int i = 0; i < args.length; i++) {
            Object value = args[i];
            int index = i + 1;
            if (value == null) {
                ps.setObject(index, null);
            } else if (value instanceof Boolean b) {
                ps.setInt(index, b ? 1 : 0);
            } else {
                ps.setObject(index, value);
            }
        }
    }

    public static List<String> columnsOf(Connection connection, String table) {
        List<Map<String, Object>> rows = query(connection, "PRAGMA table_info(\"" + table + "\")");
        List<String> names = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            names.add(String.valueOf(row.get("name")));
        }
        return names;
    }

    public static boolean tableExists(Connection connection, String table) {
        Map<String, Object> row = queryOne(
                connection,
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                table);
        return row != null;
    }

    public static void closeQuietly(Connection connection) {
        if (connection == null) {
            return;
        }
        try {
            connection.close();
        } catch (SQLException ignore) {
            // 已关闭
        }
    }
}
