# 🛠️ Ubuntu Server Initial Setup & Deployment Guide

This guide outlines the initial configuration and deployment process for a newly provisioned Ubuntu server using the [`ubuntu-deploy-scripts`](https://github.com/lowildlr10/ubuntu-deploy-scripts) repository.

---

## 📦 Prerequisites

- Access to your server via an admin user
- Your SSH private key file (`id_ed25519`)
- A GitHub repository URL of your project(s)
- Internet connection on the server

---

## 🔐 1. Connect to Server

SSH into the server using your admin user:

```bash
ssh -i id_ed25519 <admin-user>@<server-ip-or-dns>
```

---

## 📥 2. Clone Deployment Scripts

Clone the deployment scripts repository and set them as executable:

```bash
cd ~
git clone https://github.com/lowildlr10/ubuntu-deploy-scripts.git
cd ~/ubuntu-deploy-scripts
chmod +x ./*
```

---

## ⚙️ 3. Run Initial Server Setup

Run the `server_setup.sh` script to install packages and configurations:

```bash
sudo ./server_setup.sh
```

Press **Enter** when prompted to begin installation.

Once done, secure MySQL with:

```bash
sudo mysql_secure_installation
```

---

## 👤 4. Deploy New Web App System

Run the deployment script:

```bash
sudo ./deploy.sh
```

Follow the prompts and provide required information.  
Once completed, **copy and save** the output — it includes credentials for the newly created user.

---

## 🔁 5. Switch to New User

Log out:

```bash
exit
```

Download the newly generated SSH private key:

```bash
sftp -i id_ed25519 <admin-user>@<server-ip>:/home/<admin-user>/<new-username>_id_rsa
```

Connect to the new user:

```bash
ssh -i ./<new-username>_id_rsa <new-username>@<server-ip-or-dns>
```

---

## 🧹 6. Clean Default Web App Directories

Remove contents from the default web app folders:

```bash
cd ~/public_html && rm -rf ./*    # if it exists
cd ~/public_app && rm -rf ./*     # if it exists
cd ~/public_api && rm -rf ./*     # if it exists
```

---

## 📦 7. Clone Your Project

Choose your project structure and clone accordingly:

### Monolithic:
```bash
cd ~
git clone <repository-url> public_html
```

### Microservices:
```bash
cd ~
git clone <repository-url-for-app> public_app
git clone <repository-url-for-api> public_api
```

### Backend-only:
```bash
cd ~
git clone <repository-url> public_api
```

---

## 🛠️ 8. Configure Your Web App

- Set required environment/configuration files
- Set correct file and folder permissions

### 🔄 (Optional) Configure Supervisor for Queue Jobs

If your application uses background jobs (e.g. Laravel queues), run the Supervisor setup script:

```bash
./supervisor_setup.sh
```

Follow the prompt to enter the username when asked.

### Database Credentials

| Type    | Host      | Username             | Password                    |
|---------|-----------|----------------------|-----------------------------|
| MySQL   | localhost / server IP / DNS | `<new-username>` | _from deploy.sh output_ |
| Postgres| localhost / server IP / DNS | `<new-username>` | _from deploy.sh output_ |

---

## 🌐 9. (Optional) Modify Nginx Config

Modify Nginx configuration files under `~/nginx/sites-available` if needed:

### Monolithic:
```bash
sudo nano ~/nginx/sites-available/<username>_html.conf
sudo systemctl restart nginx
```

### Microservices:
```bash
sudo nano ~/nginx/sites-available/<username>_app.conf
sudo nano ~/nginx/sites-available/<username>_api.conf
sudo systemctl restart nginx
```

### Backend-only:
```bash
sudo nano ~/nginx/sites-available/<username>_api.conf
sudo systemctl restart nginx
```

---

## ⚙️ 10. Setup GitHub Actions (Optional)

Refer to your project’s `.github/workflows` configuration.  
Ensure SSH, deployment paths, and secrets are correctly configured.

---

## 🔁 Maintenance & Management

- **Deploy a new web app:** Rerun `deploy.sh`
- **Remove a deployed system:** Run `undeploy.sh` and manually clean up leftover files if needed.

---

## ✅ You're Done!

You're now ready to develop and deploy with your fully configured Ubuntu server.

> Happy hacking! 🚀
