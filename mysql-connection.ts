import mysql from 'mysql2/promise';

export interface MysqlConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}

/** Create a new MySQL connection pool from the given config. */
export function createMysqlPool(config: MysqlConfig): mysql.Pool {
  return mysql.createPool({
    host: config.host,
    port: config.port,
    user: config.user,
    password: config.password,
    database: config.database,
    waitForConnections: true,
    connectionLimit: 5,
    queueLimit: 0,
  });
}

/** Test a MySQL pool connection — returns true on success, false on failure. */
export async function testMySQLConnection(pool: mysql.Pool): Promise<boolean> {
  try {
    const connection = await pool.getConnection();
    console.log('MySQL connected successfully');
    connection.release();
    return true;
  } catch (error: any) {
    console.log('MySQL connection failed:', error.message);
    return false;
  }
}
