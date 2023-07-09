FROM debian:latest

# Install required dependencies
RUN apt-get update && apt-get install -y wget pass gnupg libegl1 libsecret-1-0 libglib2.0-0 libpulse-mainloop-glib0 fonts-dejavu

# Download and install ProtonMail Bridge
COPY protonmail-bridge.deb /
RUN dpkg -i protonmail-bridge.deb

# Cleanup
RUN rm protonmail-bridge.deb
RUN apt-get clean

# Create the configuration directory
RUN mkdir /config

# Run ProtonMail Bridge on container startup
CMD /usr/bin/protonmail-bridge --cli --config-dir /config