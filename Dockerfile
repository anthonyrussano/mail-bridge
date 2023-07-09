FROM debian:latest

# Install required dependencies
RUN apt-get update && apt-get install -y wget pass gnupg libegl1 libsecret-1-0 libglib2.0-0 libpulse-mainloop-glib0 fonts-dejavu

# Download and install ProtonMail Bridge
RUN wget -O protonmail-bridge.deb https://pin.wikip.co/api/shares/proton-mail-bridge/files/c86145e0-0c15-4228-b159-90453e6bfe82
RUN dpkg -i protonmail-bridge.deb

# Cleanup
RUN rm protonmail-bridge.deb
RUN apt-get clean

# Create the configuration directory
RUN mkdir /config

# Run ProtonMail Bridge on container startup
CMD /usr/bin/protonmail-bridge --cli
