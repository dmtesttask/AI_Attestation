#!/usr/bin/env bash

# GCP Setup & Bootstrap Script for OpenClaw "Virtual Jury"
# Run this script inside GCP Cloud Shell.

set -euo pipefail

# Harmonious colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0;0m' # No Color

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}  Інструмент автоматичного розгортання та налаштування OpenClaw GCP  ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# 1. Verification of Active GCP Project
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Помилка: Не виявлено активного проєкту GCP.${NC}"
    echo "Будь ласка, встановіть проєкт за допомогою: gcloud config set project <PROJECT_ID>"
    exit 1
fi

echo -e "${GREEN}[✔] Активний ID проєкту:${NC} $PROJECT_ID"

# 2. Enable Required APIs
echo -e "${YELLOW}[...] Увімкнення API Compute Engine та Secret Manager...${NC}"
gcloud services enable compute.googleapis.com secretmanager.googleapis.com --quiet
echo -e "${GREEN}[✔] API успішно увімкнено.${NC}"

# 3. Secure Secret Management (Secret Manager)
setup_secret() {
    local secret_name=$1
    local prompt_text=$2
    
    # Check if secret already exists
    if gcloud secrets describe "$secret_name" >/dev/null 2>&1; then
        # Check if secret has any active/enabled versions
        local has_versions
        has_versions=$(gcloud secrets versions list "$secret_name" --filter="state=ENABLED" --format="value(name)" --limit=1 2>/dev/null || echo "")
        
        if [ -n "$has_versions" ]; then
            echo -e "${GREEN}[✔] Секрет '$secret_name' вже існує та містить значення.${NC}"
            echo -n "Бажаєте оновити його значення? (y/N): "
            read -r update_val
            if [[ "$update_val" =~ ^[Yy]$ ]]; then
                # Read the secret value securely
                echo -n "$prompt_text: "
                read -s secret_val
                echo ""
                
                if [ -z "$secret_val" ]; then
                    echo -e "${RED}Помилка: Значення не може бути порожнім.${NC}"
                    exit 1
                fi
                
                # Add new version
                echo -n "$secret_val" | gcloud secrets versions add "$secret_name" --data-file=- --quiet
                echo -e "${GREEN}[✔] Значення секрету '$secret_name' оновлено.${NC}"
            fi
        else
            echo -e "${YELLOW}[!] Секрет '$secret_name' існує, але не містить активних версій.${NC}"
            # Read the secret value securely
            echo -n "$prompt_text: "
            read -s secret_val
            echo ""
            
            if [ -z "$secret_val" ]; then
                echo -e "${RED}Помилка: Значення не може бути порожнім.${NC}"
                exit 1
            fi
            
            # Add version
            echo -n "$secret_val" | gcloud secrets versions add "$secret_name" --data-file=- --quiet
            echo -e "${GREEN}[✔] Секрет '$secret_name' успішно ініціалізовано значенням.${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Секрет '$secret_name' не знайдено. Створюємо його...${NC}"
        gcloud secrets create "$secret_name" --replication-policy="automatic" --quiet
        
        # Read the secret value securely
        echo -n "$prompt_text: "
        read -s secret_val
        echo ""
        
        if [ -z "$secret_val" ]; then
            echo -e "${RED}Помилка: Значення не може бути порожнім.${NC}"
            exit 1
        fi
        
        # Add version
        echo -n "$secret_val" | gcloud secrets versions add "$secret_name" --data-file=- --quiet
        echo -e "${GREEN}[✔] Секрет '$secret_name' створено, значення збережено.${NC}"
    fi
    unset secret_val
}

setup_secret "openclaw-gemini-api-key" "Введіть ваш Gemini API Key (отриманий на aistudio.google.com)"
setup_secret "openclaw-openrouter-api-key" "Введіть ваш OpenRouter API Key (отриманий на openrouter.ai)"
setup_secret "openclaw-telegram-bot-token" "Введіть ваш токен Telegram-бота (отриманий від @BotFather)"

# 4. Service Account Setup
SA_NAME="openclaw-vm-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
    echo -e "${GREEN}[✔] Сервісний акаунт '$SA_EMAIL' вже існує.${NC}"
else
    echo -e "${YELLOW}[...] Створення сервісного акаунту '$SA_NAME'...${NC}"
    gcloud iam service-accounts create "$SA_NAME" \
        --description="Service account for OpenClaw VM to access Secret Manager" \
        --display-name="OpenClaw VM Service Account" --quiet
    echo -e "${GREEN}[✔] Сервісний акаунт створено.${NC}"
fi

# Grant secret accessor rights to the service account
echo -e "${YELLOW}[...] Надання ролі Secret Manager Accessor сервісному акаунту...${NC}"
gcloud secrets add-iam-policy-binding openclaw-gemini-api-key \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" --quiet >/dev/null

gcloud secrets add-iam-policy-binding openclaw-openrouter-api-key \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" --quiet >/dev/null

gcloud secrets add-iam-policy-binding openclaw-telegram-bot-token \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" --quiet >/dev/null
echo -e "${GREEN}[✔] Права доступу успішно налаштовано.${NC}"

# 5. Virtual Machine Provisioning
VM_NAME="openclaw-server"
ZONE="us-central1-a"

if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Інстанс '$VM_NAME' вже існує.${NC}"
    echo -n "Бажаєте перестворити його? (y/N): "
    read -r recreate
    if [[ "$recreate" =~ ^[Yy]$ ]]; then
        echo -e "${RED}[...] Видалення існуючого інстансу...${NC}"
        gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --quiet
    else
        echo -e "${GREEN}[✔] Зберігаємо існуючий інстанс. Продовжуємо...${NC}"
    fi
fi

# If instance doesn't exist, create it
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
    echo -e "${YELLOW}[...] Створення віртуальної машини (e2-medium в us-central1)...${NC}"
    gcloud compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --machine-type="e2-medium" \
        --image-family="ubuntu-2404-lts-amd64" \
        --image-project="ubuntu-os-cloud" \
        --boot-disk-size="200GB" \
        --boot-disk-type="pd-standard" \
        --network-tier="STANDARD" \
        --service-account="$SA_EMAIL" \
        --scopes="https://www.googleapis.com/auth/cloud-platform" \
        --metadata-from-file=startup-script=vm-startup.sh \
        --quiet
    echo -e "${GREEN}[✔] Віртуальну машину успішно створено!${NC}"
fi

# 6. Wait for VM and Startup Script Completion
echo -e "${YELLOW}[...] Очікування запуску SSH-демона та завершення скрипта ініціалізації...${NC}"
echo -e "${YELLOW}    (Встановлюються Node.js, OpenClaw та налаштовуються API. Це може зайняти 2-4 хвилини)${NC}"

# Check connection loop
while ! gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="echo 'Ready to connect'" --quiet >/dev/null 2>&1; do
    echo -e "${YELLOW}[...] SSH-демон ще не готовий. Повторна спроба за 10 секунд...${NC}"
    sleep 10
done
echo -e "${GREEN}[✔] З'єднання встановлено. Очікування встановлення пакетів та налаштування...${NC}"

# Wait for startup-finished flag file
while ! gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="test -f /var/tmp/startup-finished" --quiet >/dev/null 2>&1; do
    echo -e "${YELLOW}[...] Налаштування триває. Перевірка за 15 секунд...${NC}"
    sleep 15
done
echo -e "${GREEN}[✔] Встановлення та ініціалізацію OpenClaw на ВМ успішно завершено.${NC}"

# 7. Upload Agent Configurations & Rules
echo -e "${YELLOW}[...] Розгортання персонажів агентів та правил оркестрації на ВМ...${NC}"

# Create directories in target VM just in case
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="sudo -u openclaw -i mkdir -p /home/openclaw/.openclaw/agents /home/openclaw/.openclaw/workspace && mkdir -p /tmp/openclaw-agents" --quiet

# SCP the local config files to a temporary location on the VM
echo -e "${YELLOW}[...] Передача файлів...${NC}"
gcloud compute scp --recurse ./config/agents/* "${VM_NAME}:/tmp/openclaw-agents/" --zone="$ZONE" --quiet
gcloud compute scp ./config/workspace/AGENTS.md "${VM_NAME}:/tmp/AGENTS.md" --zone="$ZONE" --quiet
gcloud compute scp ./config/workspace/SOUL.md "${VM_NAME}:/tmp/SOUL.md" --zone="$ZONE" --quiet

# Move files to openclaw directory and change ownership
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="
  sudo mv /tmp/AGENTS.md /home/openclaw/.openclaw/workspace/AGENTS.md
  sudo mv /tmp/SOUL.md /home/openclaw/.openclaw/workspace/SOUL.md
  # Move each agent folder from /tmp/openclaw-agents to ~/.openclaw/agents/
  for agent_path in /tmp/openclaw-agents/* ; do
    if [ -d \"\$agent_path\" ]; then
      agent_name=\$(basename \"\$agent_path\")
      sudo rm -rf \"/home/openclaw/.openclaw/agents/\$agent_name\"
      sudo mv \"\$agent_path\" \"/home/openclaw/.openclaw/agents/\$agent_name\"
    fi
  done
  sudo rm -rf /tmp/openclaw-agents
  sudo chown -R openclaw:openclaw /home/openclaw/.openclaw
  sudo systemctl restart openclaw
" --quiet

echo -e "${GREEN}[✔] Конфігураційні файли успішно завантажено та активовано!${NC}"

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${GREEN}  УСПІХ: Розгортання OpenClaw успішно завершено!${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo -e "Тепер ви можете підключитися до вашого сервера за допомогою команди:"
echo -e "  ${YELLOW}gcloud compute ssh $VM_NAME --zone=$ZONE${NC}"
echo ""
echo -e "Корисні CLI-операції на сервері:"
echo -e "  - Перегляд логів Gateway в реальному часі: ${YELLOW}journalctl -u openclaw -f${NC}"
echo -e "  - Перевірка списку агентів:              ${YELLOW}openclaw agents list${NC}"
echo -e "  - Перевірка статусу системи:             ${YELLOW}openclaw gateway status${NC}"
echo ""
echo -e "${YELLOW}Наступні кроки:${NC}"
echo -e "1. Відкрийте Telegram та надішліть будь-яке повідомлення вашому боту."
echo -e "2. Бот відповість вам повідомленням з кодом сопряження (pairing code)."
echo -e "3. Підтвердіть сопряження на ВМ, виконавши команду: ${YELLOW}openclaw pairing approve telegram <КОД>${NC}"
echo -e "=====================================================================${NC}"
