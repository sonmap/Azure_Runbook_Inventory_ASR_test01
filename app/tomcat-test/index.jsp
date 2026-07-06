<%@ page import="java.sql.*" %>
<%
String mysqlHost = System.getenv("MYSQL_HOST");
String mysqlDb   = System.getenv("MYSQL_DB");
String mysqlUser = System.getenv("MYSQL_USER");
String mysqlPass = System.getenv("MYSQL_PASSWORD");

if (mysqlHost == null) mysqlHost = "my-mysql.mysql.database.azure.com";
if (mysqlDb == null) mysqlDb = "appdb";
if (mysqlUser == null) mysqlUser = "appuser";

String jdbcUrl = "jdbc:mysql://" + mysqlHost + ":3306/" + mysqlDb + "?useSSL=true&serverTimezone=UTC";
String dbStatus = "NOT TESTED";
String dbMessage = "";

try {
    Class.forName("com.mysql.cj.jdbc.Driver");
    Connection conn = DriverManager.getConnection(jdbcUrl, mysqlUser, mysqlPass);
    Statement stmt = conn.createStatement();
    ResultSet rs = stmt.executeQuery("select now() as now_time");
    if (rs.next()) {
        dbStatus = "OK";
        dbMessage = rs.getString("now_time");
    }
    rs.close();
    stmt.close();
    conn.close();
} catch (Exception e) {
    dbStatus = "FAIL";
    dbMessage = e.getMessage();
}
%>
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Azure ASR Tomcat DR Test</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; }
    .ok { color: green; font-weight: bold; }
    .fail { color: red; font-weight: bold; }
    table { border-collapse: collapse; }
    td, th { border: 1px solid #ccc; padding: 8px 12px; }
  </style>
</head>
<body>
  <h1>Azure ASR Tomcat DR Test</h1>
  <p>AP 서버 Tomcat 화면 테스트 페이지입니다.</p>

  <table>
    <tr><th>Item</th><th>Value</th></tr>
    <tr><td>Server Name</td><td><%= java.net.InetAddress.getLocalHost().getHostName() %></td></tr>
    <tr><td>Client IP</td><td><%= request.getRemoteAddr() %></td></tr>
    <tr><td>MySQL Host</td><td><%= mysqlHost %></td></tr>
    <tr><td>MySQL DB</td><td><%= mysqlDb %></td></tr>
    <tr><td>DB Status</td><td class="<%= "OK".equals(dbStatus) ? "ok" : "fail" %>"><%= dbStatus %></td></tr>
    <tr><td>DB Message</td><td><%= dbMessage %></td></tr>
  </table>
</body>
</html>
