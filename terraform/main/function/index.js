// Cloud Function: автозапуск прерываемой ВМ, если её прервали.
// INSTANCE_ID подаётся через переменные окружения из Terraform.
// Авторизация — IAM-токен сервисного аккаунта, под которым
// функция выполняется (context.token).
export const handler = async (event, context) => {
  const instanceId = process.env.INSTANCE_ID;
  const headers = {
    Authorization: `Bearer ${context.token.access_token}`,
  };
  const base = "https://compute.api.cloud.yandex.net/compute/v1/instances";

  // Узнаём текущий статус ВМ
  const res = await fetch(`${base}/${instanceId}`, { headers });
  const instance = await res.json();

  // Запускаем только если ВМ остановлена (её прервали)
  if (instance.status !== "STOPPED") {
    return {
      statusCode: 200,
      body: { instanceId, status: instance.status },
    };
  }

  await fetch(`${base}/${instanceId}:start`, { method: "POST", headers });
  return {
    statusCode: 200,
    body: { instanceId, action: "start requested" },
  };
};
